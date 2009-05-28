package CPANPLUS::Dist::Arch;

use warnings;
use strict;

use base qw(CPANPLUS::Dist::Base);

use File::Spec::Functions  qw(catfile catdir);
use Module::CoreList       qw();
use CPANPLUS::Error        qw(error msg);
use List::MoreUtils        qw(uniq);
use Digest::MD5            qw();
use Pod::Select            qw();
use File::Path             qw(mkpath);
use File::Copy             qw(copy);
use File::stat             qw(stat);
use DynaLoader             qw();
use IPC::Cmd               qw(run can_run);
use English                qw(-no_match_vars);

use Data::Dumper;


our $VERSION = '0.09';

#----------------------------------------------------------------------
# CLASS CONSTANTS
#----------------------------------------------------------------------

my $MKPKGCONF_FQP = '/etc/makepkg.conf';
my $CPANURL       = 'http://search.cpan.org';
my $ROOT_USER_ID  = 0;

my $NONROOT_WARNING = <<'END_MSG';
In order to install packages as a non-root user (highly recommended)
you must have a sudo-like command specified in your CPANPLUS
configuration.
END_MSG

# Patterns to use when using pacman for finding library owners.
my $PACMAN_FINDOWN     = qr/\A[^ ]+ is owned by (\w+) ([\w.]+)/;
my $PACMAN_FINDOWN_ERR = qr/\Aerror:/;


# Override a package's name to conform to packaging guidelines.
# Copied entries from CPANPLUS::Dist::Pacman and alot more
# from searching for packages with perl in their name in
# [extra] and [community]
my $PKGNAME_OVERRIDES =
{ map { split /[\s=]+/ } split /\s*\n+\s*/, <<'END_OVERRIDES' };

libwww-perl    = perl-libwww
glade-perl-two = perl-glade-two
aceperl        = perl-ace

Gnome2-GConf   = gconf-perl
Gtk2-GladeXML  = glade-perl
Glib           = glib-perl
Gnome2         = gnome-perl
Gnome2-VFS     = gnome-vfs-perl
Gnome2-Canvas  = gnomecanvas-perl
Gtk2           = gtk2-perl
XML-LibXML     = libxml-perl
mod_perl       = mod_perl
Pango          = pango-perl
XML-Parser     = perlxml0
SDL_Perl       = sdl_perl
shorewall-perl = shorewall-perl

END_OVERRIDES

=for Mini-Template Format
    The template format is very simple, to insert a template variable
    use [% var_name %] this will insert the template variable's value.
 
    The print_template() sub will throw: 'Template variable ... was
    not provided' if the variable given by var_name is not defined.
 
    [% IF var_name %] ... [% FI %] will remove the ... stuff if the
    variable named var_name is not set to a true value.
 
    WARNING: IF blocks cannot be nested!
 
    See the _process_template method below.

=cut

# Crude template for our PKGBUILD script
my $PKGBUILD_TEMPL = <<'END_TEMPL';
# Contributor: [% packager %]
# Generator  : CPANPLUS::Dist::Arch [% version %]
pkgname='[% pkgname %]'
pkgver='[% pkgver %]'
pkgrel='1'
pkgdesc="[% pkgdesc %]"
arch=('i686' 'x86_64')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=([% pkgdeps %])
url='[% disturl %]'
source=('[% srcurl %]')
md5sums=('[% md5sum %]')

build() {
  export PERL_MM_USE_DEFAULT=1
  { cd "${srcdir}/[% distdir %]" &&
[% IF is_makemaker %]
    perl Makefile.PL INSTALLDIRS=vendor &&
    make &&
[% skiptest_comment %]   make test &&
    make DESTDIR="${pkgdir}/" install;
  } || return 1;
[% FI %]
[% IF is_modulebuild %]
    perl Build.PL --installdirs=vendor --destdir="$pkgdir" &&
    ./Build &&
[% skiptest_comment %]   ./Build test &&
    ./Build install;
  } || return 1;
[% FI %]

  find "$pkgdir" -name .packlist -delete
  find "$pkgdir" -name perllocal.pod -delete
}
END_TEMPL

#----------------------------------------------------------------------
# CLASS GLOBALS
#----------------------------------------------------------------------

our ($PKGDEST, $PACKAGER);

$PACKAGER = 'Anonymous';

READ_CONF:
{
    # Read makepkg.conf to see if there are system-wide settings
    my $mkpkgconf;
    if ( ! open $mkpkgconf, '<', $MKPKGCONF_FQP ) {
        error "Could not read $MKPKGCONF_FQP: $!";
        last READ_CONF;
    }

    my %cfg_vars = ( 'PKGDEST'  => \$PKGDEST,
                     'PACKAGER' => \$PACKAGER );

    my $cfg_var_match = '(' . join( '|', keys %cfg_vars ) . ')';

    while (<$mkpkgconf>) {
        if (/ ^ $cfg_var_match = "? (.*) "? $ /xmso) {
            ${$cfg_vars{$1}} = $2;
        }
    }
    close $mkpkgconf or error "close on makepkg.conf: $!";
}

#-------------------------------------------------------------------------------
# PUBLIC CPANPLUS::Dist::Base Interface
#-------------------------------------------------------------------------------

=for Interface Methods
See L<CPANPLUS::Dist::Base>'s documentation for a description of the
purpose of these functions.  All of these "interface" methods override
Base's default actions in order to create our packages.

=cut

#---INTERFACE METHOD---
# Purpose  : Checks if we have makepkg and pacman installed
# Returns  : 1 - if we have the tools needed to make a pacman package.
#            0 - if we don't think so.
#----------------------
sub format_available
{
    for my $prog ( qw/ makepkg pacman / ) {
        if ( ! can_run($prog) ) {
            error "CPANPLUS::Dist::Arch needs to run $prog, to work properly";
            return 0;
        }
    }
    return 1;
}

#---INTERFACE METHOD---
# Purpose  : Initializes our object internals to get things started
# Returns  : 1 always
#----------------------
sub init
{
    my $self = shift;

    $self->status->mk_accessors( qw{ pkgname  pkgver  pkgbase pkgdesc
                                     pkgurl   pkgsize pkgarch
                                     builddir destdir } );
    return 1;
}

#---INTERFACE METHOD---
# Purpose  : Prepares the files and directories we will need to build a
#            package.  Also prepares any data we expect to have later,
#            on a per-object basis.
# Return   : 1 if ok, 0 on error.
# Postcond : Sets $self->status->prepare to 1 or 0 on success or
#            failure.
#----------------------
sub prepare
{
    my $self = shift;

    my $status   = $self->status;                # Private hash
    my $module   = $self->parent;                # CPANPLUS::Module
    my $intern   = $module->parent;              # CPANPLUS::Internals
    my $conf     = $intern->configure_object;    # CPANPLUS::Configure
    my $distcpan = $module->status->dist_cpan;   # CPANPLUS::Dist::MM or
                                                 # CPANPLUS::Dist::Build

    $self->_prepare_status;
    $status->prepared(0);

    # Call CPANPLUS::Dist::Base's prepare to resolve our pre-reqs.
    return $self->SUPER::prepare(@_);
}

#---INTERFACE METHOD---
# Purpose  : Creates the pacman package using the 'makepkg' command.
#----------------------
sub create
{
    my ($self, %opts) = (shift, @_);

    my $status   = $self->status;                # Private hash
    my $module   = $self->parent;                # CPANPLUS::Module
    my $intern   = $module->parent;              # CPANPLUS::Internals
    my $conf     = $intern->configure_object;    # CPANPLUS::Configure
    my $distcpan = $module->status->dist_cpan;   # CPANPLUS::Dist::MM or
                                                 # CPANPLUS::Dist::Build

    # Create directories for building and delivering the new package.
    for my $dir ( $status->pkgbase, $status->destdir ) {
        if ( -e $dir ) {
            die "$dir exists but is not a directory!" if ( ! -d _ );
            die "$dir exists but is read-only!"       if ( ! -w _ );
        }
        else {
            mkpath $dir
                or die qq{failed to create directory '$dir': $OS_ERROR};
            if ( $opts{verbose} ) { msg "Created directory $dir" }
        }
    }

    my $pkg_type = $opts{pkg} || $opts{pkgtype} || 'bin';
    $pkg_type = lc $pkg_type;

    die qq{Invalid package type requested: "$pkg_type"
Package type must be 'bin' or 'src'}
        unless ( $pkg_type =~ /^(?:bin|src)$/ );

    if ( $opts{verbose} ) {
        my %fullname = ( bin => 'binary', src => 'source' );
        msg "Creating a $fullname{$pkg_type} pacman package";
    }

    if ( $pkg_type eq 'bin' ) {
        # Use CPANPLUS::Dist::Base to make packages for pre-requisites...
        # (starts the packaging process for any missing ones)
        my @ok_resolve_args = qw/ verbose target force prereq_build /;
        my %resolve_args = map { ( exists $opts{$_}  ?
                                   ($_ => $opts{$_}) : () ) } @ok_resolve_args;

        $distcpan->_resolve_prereqs( %resolve_args,
                                     'format'  => ref $self,
                                     'prereqs' => $module->status->prereqs );
    }

    # Prepare our file name paths for pkgfile and source tarball...
    my $pkgfile = join '-', ( qq{${\$status->pkgname}},
                              qq{${\$status->pkgver}},
                              ( $pkg_type eq q{bin}
                                ? ( q{1}, qq{${\$status->pkgarch}.pkg.tar.gz} )
                                : q{1.src.tar.gz} )
                             );

    my $srcfile_fqp = $status->pkgbase . '/' . $module->package;
    my $pkgfile_fqp = $status->pkgbase . "/$pkgfile";

    # Prepare our 'makepkg' package building directory,
    # namely the PKGBUILD and source tarball files...
    if ( ! -e $srcfile_fqp ) {
        my $tarball_fqp = $module->_status->fetch;
        link $tarball_fqp, $srcfile_fqp
            or error "Failed to create link to $tarball_fqp: $OS_ERROR";
    }

    $self->create_pkgbuild($self->status->pkgbase);

    # Wrap it up!
    chdir $status->pkgbase or die "chdir: $OS_ERROR";
    my $makepkg_cmd = join ' ', ( 'makepkg',
                                  ( $EUID == 0         ? '--asroot'   : () ),
                                  ( $pkg_type eq 'src' ? '--source'   : () ),
                                  ( !$opts{verbose}    ? '>/dev/null' : () ),
                                 );

    # I tried to use IPC::Cmd here, but colors didn't work...
    system $makepkg_cmd;
    if ($CHILD_ERROR) {
        error ( $CHILD_ERROR & 127
                ? sprintf "makepkg failed with signal %d", $CHILD_ERROR & 127
                : sprintf "makepkg returned abnormal status: %d", $CHILD_ERROR >> 8
               );
        return 0;
    }

    my $destdir = $opts{destdir} || $status->destdir;
    my $destfile_fqp = catfile( $destdir, $pkgfile );
    if ( ! rename $pkgfile_fqp, $destfile_fqp ) {
        error "failed to move $pkgfile to $destfile_fqp: $OS_ERROR";
        return 0;
    }

    $status->dist($destfile_fqp);
    return $status->created(1);
}

#---INTERFACE METHOD---
# Purpose  : Installs the package file (.pkg.tar.gz) using sudo and
#            pacman.
# Comments : Called automatically on pre-requisite packages
#----------------------
sub install
{
    my ($self, %opts) = (shift, @_);

    my $status = $self->status;             # Private hash
    my $module = $self->parent;             # CPANPLUS::Module
    my $intern = $module->parent;           # CPANPLUS::Internals
    my $conf   = $intern->configure_object; # CPANPLUS::Configure

    my $pkgfile_fpq = $status->dist
        or die << 'END_ERROR';
Path to package file has not been set.
Someone is using CPANPLUS::Dist::Arch incorrectly.
Tell them to call create() before install().
END_ERROR

    die "Package file $pkgfile_fpq was not found" if ( ! -f $pkgfile_fpq );

    # Make sure the user has access to install a package...
    my $sudocmd = $conf->get_program('sudo');
    if ( $EFFECTIVE_USER_ID != $ROOT_USER_ID ) {
        if ( $sudocmd ) {
            system "$sudocmd pacman -U $pkgfile_fpq";
        }
        else {
            error $NONROOT_WARNING;
            return 0;
        }
    }
    else { system "pacman -U $pkgfile_fpq"; }

    if ($CHILD_ERROR) {
        error ( $CHILD_ERROR & 127
                ? sprintf "pacman failed with signal %d",        $CHILD_ERROR & 127
                : sprintf "pacman returned abnormal status: %d", $CHILD_ERROR >> 8
               );
        return 0;
    }

    return $status->installed(1);
}

#-------------------------------------------------------------------------------
# PUBLIC METHODS
#-------------------------------------------------------------------------------

sub set_destdir
{
    die 'Invalid arguments to set_destdir' if ( @_ != 2 );
    my ($self, $destdir) = @_;
    $self->status->destdir($destdir);
    return $destdir;
}

sub get_destdir
{
    my $self = shift;
    return $self->status->destdir;
}

sub get_pkgvars
{
    die 'Invalid arguments to get_pkgvars' if ( @_ != 1 );

    my $self   = shift;
    my $status = $self->status;

    die 'prepare() must be called before get_pkgvars()'
        unless ( $status->prepared );

    return ( pkgname  => $status->pkgname,
             pkgver   => $status->pkgname,
             pkgdesc  => $status->pkgdesc,
             depends  => scalar $self->_translate_cpan_deps,
             url      => $self->_get_disturl,
             source   => $self->_get_srcurl,
             md5sums  => $self->_calc_tarballmd5,

             depshash => { $self->_translate_cpan_deps },
            );
}

sub get_pkgvars_ref
{
    die 'Invalid arguments to get_pkgvars_ref' if ( @_ != 1 );

    my $self = shift;
    return { $self->get_pkgvars };
}

sub get_pkgbuild
{
    my ($self) = @_;

    my $status  = $self->status;
    my $module  = $self->parent;
    my $conf    = $module->parent->configure_object;

    die 'prepare() must be called before get_pkgbuild()'
        unless $status->prepared;

    my $pkgdeps = $self->_translate_cpan_deps;
    my $pkgdesc = $status->pkgdesc;
    my $extdir  = $module->package;
    $extdir     =~ s/ [.] ${\$module->package_extension} \z //xms;
    $pkgdesc    =~ s/ ([\$\"\`\!]) / \\$1 /gxms; # Quote our package desc for bash.

    my $templ_vars = { packager  => $PACKAGER,
                       version   => $VERSION,

                       pkgname   => $status->pkgname,
                       pkgver    => $status->pkgver,
                       pkgdesc   => $pkgdesc,
                       pkgdeps   => $pkgdeps,

                       disturl   => $self->_get_disturl(),
                       srcurl    => $self->_get_srcurl(),
                       md5sum    => $self->_calc_tarballmd5(),

                       distdir   => $extdir,

                       skiptest_comment => ( $conf->get_conf('skiptest')
                                             ? '#' : ' ' )
                      };

    my $dist_type = $module->status->installer_type;
    @{$templ_vars}{'is_makemaker', 'is_modulebuild'} =
        ( $dist_type eq 'CPANPLUS::Dist::MM'    ? (1, 0) :
          $dist_type eq 'CPANPLUS::Dist::Build' ? (0, 1) :
          die "unknown Perl module installer type: '$dist_type'" );

    return scalar $self->_process_template( $PKGBUILD_TEMPL,
                                            $templ_vars );
}

sub create_pkgbuild
{
    die 'Invalid arguments to create_pkgbuild' if ( @_ != 2 );
    my ($self, $destdir) = @_;

    die qq{Invalid directory passed to create_pkgbuild: "$destdir" ...
Directory does not exist or is not writeable}
        unless ( -d $destdir && -w _ );

    my $pkgbuild_text = $self->get_pkgbuild;
    my $fqpath        = catfile( $destdir, 'PKGBUILD' );

    open my $pkgbuild_file, '>', $fqpath
        or die "failed to open new PKGBUILD: $OS_ERROR";
    print $pkgbuild_file $pkgbuild_text;
    close $pkgbuild_file
        or die "failed to close new PKGBUILD: $OS_ERROR";

    return;
}

#-------------------------------------------------------------------------------
# PRIVATE INSTANCE METHODS
#-------------------------------------------------------------------------------

#---INSTANCE METHOD---
# Usage   : my $pkgname = $self->_translate_name($dist_name);
# Purpose : Converts a module's dist[ribution tarball] name to an
#           Archlinux style perl package name.
# Params  : $dist_name - The name of the distribution (ex: Acme-Drunk)
# Returns : The Archlinux perl package name (ex: perl-acme-drunk).
#---------------------
sub _translate_name
{
    die "Invalid arguments to _translate_name method" if @_ != 2;
    my ($self, $distname) = @_;

    # Override this package name if there is one specified...
    return $PKGNAME_OVERRIDES->{$distname}
        if $PKGNAME_OVERRIDES->{$distname};

    # Package names should be lowercase and consist of alphanumeric
    # characters only (and hyphens!)...
    $distname =  lc $distname;
    $distname =~ tr/_/-/;
    $distname =~ tr/-a-z0-9//cd;
    $distname =~ tr/-/-/s;

    # Delete leading or trailing hyphens...
    $distname =~ s/\A-//;
    $distname =~ s/-\z//;

    die qq{Dist name '$distname' completely violates packaging standards}
        if ( ! $distname );

    if ( $distname !~ / (?: \A perl ) | (?: -perl \z ) /xms ) {
        $distname = "perl-$distname";
    }

    return $distname;
}

#---INSTANCE METHOD---
# Purpose  : Convert a module's CPAN distribution version into our more
#            restrictive pacman package version number.
#---------------------
sub _translate_version
{
    die "Invalid arguments to _translate_version method" if @_ != 2;
    my ($self, $version) = @_;

    # Package versions should be letters, numbers and decimal points only...
    $version =~ tr/_-/../s;
    $version =~ tr/a-zA-Z0-9.//cd;
    return $version;
}

#---INSTANCE METHOD---
# Usage    : my $deps_str = $self->_translate_cpan_deps()
# Purpose  : Convert CPAN prerequisites into pacman package dependencies
# Returns  : String to be appended after 'depends=' in PKGBUILD file,
#            without parenthesis.
#---------------------
sub _translate_cpan_deps
{
    die 'Invalid arguments to _translate_cpan_deps method'
        if @_ != 1;
    my ($self) = @_;

    my %pkgdeps;

    my $module  = $self->parent;
    my $backend = $module->parent;
    my $prereqs = $module->status->prereqs;

    CPAN_DEP_LOOP:
    for my $modname ( keys %{$prereqs} ) {
        my $depver = $prereqs->{$modname};

        # Sometimes a perl version is given as a prerequisite
        if ( $modname eq 'perl' ) {
            $pkgdeps{perl} = $depver;
            next CPAN_DEP_LOOP;
        }

        # Ignore modules included with this version of perl...
        next CPAN_DEP_LOOP
            if ( exists $Module::CoreList::version{0+$]}->{$modname} );

        # Translate the module's distribution name into a package name...
        my $modobj  = $backend->parse_module( module => $modname );
        my $pkgname = $self->_translate_name( $modobj->package_name );

        $pkgdeps{$pkgname} = $self->_translate_version( $depver );
    }

    # Default to requiring the current perl version used to compile
    # the module if there is no explicit perl version required...
    $pkgdeps{perl} ||= sprintf '%vd', $PERL_VERSION;

    # Merge in the XS C library package deps...
    my $xs_deps = $self->_translate_xs_deps;
#    print STDERR Dumper($xs_deps);

    XSDEP_LOOP:
    while ( my ($name, $ver) = each %$xs_deps ) {
        # TODO: report this error?
        next XSDEP_LOOP if ( exists $pkgdeps{$name} );
        $pkgdeps{$name} = $ver;
    }

    # Return a hash if in list context or return a string representing
    # the depends= line in the PKGBUILD if caller wants a scalar.
    return %pkgdeps if ( wantarray );

    return ( join ' ',
             map { $pkgdeps{$_} ? qq{'${_}>=$pkgdeps{$_}'} : qq{'$_'} }
             sort keys %pkgdeps );
}

#---INSTANCE METHOD---
# Usage    : $pkgdesc = $self->_prepare_pkgdesc();
# Purpose  : Tries to find a module's "abstract" short description for
#            use as a package description.
# Postcond : Sets the $self->status->pkgdesc accessor to the found
#            package description.
# Returns  : The package short description.
# Comments : We search through the META.yml file, the main module's .pm file,
#            .pod file, and then the README file.
#---------------------
sub _prepare_pkgdesc
{
    die 'Invalid arguments to _prepare_pkgdesc method' if @_ != 1;
    my ($self) = @_;
    my ($status, $module, $pkgdesc) = ($self->status, $self->parent);

    # Registered modules have their description stored in the object.
    return $status->pkgdesc( $module->description )
        if ( $module->description );

    # First, try to find the short description in the META.yml file.
    METAYML:
    {
        my $metayml;
        unless ( open $metayml, '<', $module->status->extract().'/META.yml' ) {
            #error "Could not open META.yml to get pkgdesc: $!";
            last METAYML;
        }

        while ( <$metayml> ) {
            chomp;
            if ( ($pkgdesc) = /^abstract:\s*(.+)/) {
                $pkgdesc = $1 if ( $pkgdesc =~ /\A'(.*)'\z/ );
                close $metayml;
                return $status->pkgdesc($pkgdesc);
            }
        }
        close $metayml;
    }

    # Next, parse the source file or pod file for a NAME section...
    my $podselect = Pod::Select->new;
    $podselect->select('NAME');
    my $modname   = $module->name;

    # We use the package name because there is usually a module file
    # with the exact same name as the package file.
    #
    # We want the main module's description, just in case the user requested
    # a lesser module in the same package file.
    #
    # Assume the main .pm or .pod file is under lib/Module/Name/Here.pm
    my $mainmod_file = $module->package_name;

    $mainmod_file =~ tr{-}{/}s;
    $mainmod_file = catfile( $module->status->extract, 'lib', $mainmod_file );

    PODSEARCH:
    for my $podfile_path ( map { "$mainmod_file.$_" } qw/pm pod/ ) {
        my $name_section = '';

        next PODSEARCH unless ( -e $podfile_path );
        open my $podfile, '<', $podfile_path
            or next PODSEARCH;

        open my $podout, '>', \$name_section
            or die "failed open on filehandle to string: $!";
        $podselect->parse_from_filehandle( $podfile, $podout );

        close $podfile;
        close $podout
            or die "failed close on filehandle to string: $!";

        next PODSEARCH unless ($name_section);

        # Remove formatting codes.
        $name_section =~ s{ [IBCLEFSXZ]  <(.*?)>  }{$1}gxms;
        $name_section =~ s{ [IBCLEFSXZ] <<(.*?)>> }{$1}gxms;

        # The short desc is on a line beginning with 'Module::Name - '
        return $status->pkgdesc($pkgdesc)
            if ( ($pkgdesc) = $name_section =~ / ^ \s* $modname [\s-]+ (.+?) $ /xms );
    }

    # Last, try to find it in in the README file
    README:
    {
        open my $readme, '<', $module->status->extract . '/README'
            or last README;
        #   error( "Could not open README to get pkgdesc: $!" ), return undef;

        my $modname = $module->name;
        while ( <$readme> ) {
            chomp;
            if ( (/^NAME/ ... /^[A-Z]+/) # limit ourselves to a NAME section
                 && ( ($pkgdesc) = / ^ \s* ${modname} [\s\-]+ (.+) $ /oxms) ) {
                close $readme;
                return $status->pkgdesc($pkgdesc);
            }
        }
        close $readme;
    }

    return $status->pkgdesc(q{});
}

#---INSTANCE METHOD---
# Usage    : $self->_prepare_status()
# Purpose  : Prepares all the package-specific accessors in our $self->status
#            accessor object (of the class Object::Accessor).
# Postcond : Accessors assigned to: pkgname pkgver pkgbase pkgarch
#                                   destdir
# Returns  : The object's status accessor.
#---------------------
sub _prepare_status
{
    die 'Invalid arguments to _prepare_status method' if @_ != 1;
    my $self     = shift;
    my $status   = $self->status; # Private hash
    my $module   = $self->parent; # CPANPLUS::Module
    my $conf     = $module->parent->configure_object;

    my $our_base = catdir( $conf->get_conf('base'),
                           ( sprintf "%vd", $PERL_VERSION ),
                           'pacman' );

    # Watchout if this was set explicitly with set_destdir() method
    if ( !$status->destdir ) {
        $status->destdir( $PKGDEST || catdir( $our_base, 'pkg' ) );
    }

    my ($pkgver, $pkgname)
        = ( $self->_translate_version($module->package_version),
            $self->_translate_name($module->package_name) );

    my $pkgbase = catdir( $our_base, 'build', "$pkgname-$pkgver" );
    my $pkgarch = `uname -m`;
    chomp $pkgarch;

    foreach ( $pkgname, $pkgver, $pkgbase, $pkgarch ) {
        die "A package variable is invalid" unless defined;
    }

    $status->pkgname($pkgname);
    $status->pkgver ($pkgver );
    $status->pkgbase($pkgbase);
    $status->pkgarch($pkgarch);

    $self->_prepare_pkgdesc();

    return $status;
}

#---INSTANCE METHOD---
# Usage    : my $pkgurl = $self->_get_disturl()
# Purpose  : Creates a nice, version agnostic homepage URL for the distribution.
# Returns  : URL to the distribution's web page on CPAN.
#---------------------
sub _get_disturl
{
    die 'Invalid arguments to _get_disturl method' if @_ != 1;
    my $self   = shift;
    my $module = $self->parent;

    my $distname  = $module->package_name;
    return join '/', $CPANURL, 'dist', $distname;
}

#---INSTANCE METHOD---
# Usage    : my $srcurl = $self->_get_srcurl()
# Purpose  : Generates the standard cpan download link for the source tarball.
# Returns  : URL to the distribution's tarball on CPAN.
#---------------------
sub _get_srcurl
{
    die 'Invalid arguments to _get_srcurl method' if @_ != 1;
    my ($self) = @_;
    my $module = $self->parent;

    return join '/', $CPANURL, 'CPAN', $module->path, $module->package;
}

#---INSTANCE METHOD---
# Usage    : my $md5hex = $self->calc_tarballmd5()
# Purpose  : Returns the hex md5 string for the source (dist) tarball
#            of the module.
# Throws   : failed to get md5 of <filename>: ...
# Returns  : The MD5 sum of the .tar.gz file in hex string form.
#---------------------
sub _calc_tarballmd5
{
    my ($self) = @_;
    my $module = $self->parent;

    my $tarball_fqp = $module->_status->fetch;
#    my $tarball_fqp = $self->status->pkgbase . '/' . $module->package;
    open my $distfile, '<', $tarball_fqp
        or die "failed to get md5 of $tarball_fqp: $OS_ERROR";

    my $md5 = Digest::MD5->new;
    $md5->addfile($distfile);
    close $distfile;

    return $md5->hexdigest;
}

#---INSTANCE METHOD---
# Usage    : $self->_process_template( $templ, $templ_vars );
# Purpose  : Processes IF blocks and fills in a template with supplied variables.
# Params   : templ       - A scalar variable containing the template
#            templ_vars  - A hashref of template variables that you can refer to
#                          in the template to insert the variable's value.
# Throws   : 'Template variable %s was not provided' is thrown if a template
#            variable is used in $templ but not provided in $templ_vars, or
#            it is undefined.
# Returns  : String of the template with all variables filled inserted.
#---------------------
sub _process_template
{
    die "Invalid arguments to _template_out" if @_ != 3;
    my ($self, $templ, $templ_vars) = @_;

    die 'templ_var parameter must be a hashref'
        if ( ref $templ_vars ne 'HASH' );

    $templ =~ s{ \[% \s* IF \s+ (\w+) \s* %\] \n? # opening IF
                 (.+?)                            # enclosed text
                 \[% \s* FI \s* %\] \n? }         # closing IF
               {$templ_vars->{$1} ? $2 : ''}xmseg;

    $templ =~ s{ \[% \s* (\w+) \s* %\] }
               { ( defined $templ_vars->{$1}
                   ? $templ_vars->{$1}
                   : die "Template variable $1 was not provided" )
               }xmseg;

    return $templ;
}

#-----------------------------------------------------------------------------
# XS module library dependency hunting
#-----------------------------------------------------------------------------

#---INSTANCE METHOD---
# Usage    : $deps_ref = $self->_translate_cs_deps;
# Purpose  : Attempts to find non-perl dependencies in XS modules.
# Returns  : A hashref of 'package name' => 'minimum version'.
#            (Minimum version will be the current installed version of the library)
#---------------------
sub _translate_xs_deps
{
    my $self = shift;

    my $modstat   = $self->parent->status;
    my $inst_type = $modstat->installer_type;
    my $distcpan  = $modstat->dist_cpan;

    # Delegate to the other methods depending on the dist type...
    my $libs_ref = ( $inst_type eq 'CPANPLUS::Dist::MM'    ?
                     $self->_get_mm_xs_deps($distcpan)     :
                     $inst_type eq 'CPANPLUS::Dist::Build' ?
                     $self->_get_mb_xs_deps($distcpan)     :
                     die qq{Unknown installer type "$inst_type"} );

    # Turn the linker flags into libraries and packages
    return +{ map { ($self->_get_lib_pkg($_)) }
              @$libs_ref };
}

#---INSTANCE METHOD---
# Usage    : %pkg = $self->_get_lib_pkg($lib)
# Params   : $lib - Can be a dynamic library name, with/without lib prefix
#                   or the -l<name> flag that is passed to the linker.
#                   (anything DynaLoader::dl_findfile accepts)
# Returns  : A hash (or two element list) of 'package name' => 'installed version'
#            or an empty list if the lib/package owner could not be found.
#---------------------
sub _get_lib_pkg
{
    my ($self, $libname) = @_;

    my $lib_fqp = DynaLoader::dl_findfile($libname)
        or return ();
    my $result = `pacman -Qo $lib_fqp`;
    chomp $result;

    if ( $result =~ /$PACMAN_FINDOWN_ERR/ ) {
        error qq{Could not find owner of linked library "$libname", ignoring.};
        return ();
    }

    my ($pkgname, $pkgver) = $result =~ /$PACMAN_FINDOWN/;
    return ($pkgname => $pkgver);
}

#---INSTANCE METHOD---
# Usage    : my $deps_ref = $self->_get_mm_xs_deps($dist_obj);
# Params   : $dist_obj - A CPANPLUS::Dist::MM object
# Returns  : Arrayref of library flags (-l...) passed to the linker on build.
#---------------------
sub _get_mm_xs_deps
{
    my ($self, $dist) = @_;

    my $field_srch = '\A(?:EXTRALIBS|LDLOADLIBS|BSLOADLIBS) = (.+)\z';

    my $mkfile_fqp = $dist->status->makefile
        or die "Internal error: makefile() path is unset in our object";

    open my $mkfile, '<', $mkfile_fqp
        or die "Internal error: failed to open Makefile at $mkfile_fqp ... $!";
    my @libs = uniq map { chomp; (/$field_srch/o) } <$mkfile>;
    close $mkfile;

    return [ grep { /\A-l/ } map { split } @libs ];
}

#---INSTANCE METHOD---
# Usage    : my $deps_ref = $self->_get_mb_xs_deps($dist_obj);
# Params   : $dist_obj - A CPANPLUS::Dist::Build object
# Returns  : Arrayref of library flags (-l...) passed to the linker on build.
#---------------------
sub _get_mb_xs_deps
{
    my ($self, $dist) = @_;

    my $mbobj = $dist->status->_mb_object;
    my $linker_flags = $mbobj->extra_linker_flags;

    return [ uniq grep { /\A-l/ } map { split } @{$linker_flags} ];
}

1; # End of CPANPLUS::Dist::Arch
