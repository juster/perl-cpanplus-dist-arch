package CPANPLUS::Dist::Arch;

use warnings;
use strict;

use base 'CPANPLUS::Dist::Base';

use File::Spec::Functions  qw(catfile catdir);
use Module::CoreList       qw();
use CPANPLUS::Error        qw(error msg);
use Digest::MD5            qw();
use File::Path             qw(mkpath);
use File::Copy             qw(copy);
use File::stat             qw(stat);
use IPC::Cmd               qw(run can_run);
use Readonly               qw(Readonly);
use English                qw(-no_match_vars);

our $VERSION = '0.04';

####
#### CLASS CONSTANTS
####

Readonly my $MKPKGCONF_FQP => '/etc/makepkg.conf';
Readonly my $CPANURL       => 'http://search.cpan.org';
Readonly my $ROOT_USER_ID  => 0;

Readonly my $NONROOT_WARNING => <<'END_MSG';
In order to install packages as a non-root user (highly recommended)
you must have a sudo-like command specified in your CPANPLUS
configuration.
END_MSG


# Override a package's name to conform to packaging guidelines.
# Copied entries from CPANPLUS::Dist::Pacman.
Readonly my $PKGNAME_OVERRIDES =>
{ map { split /[\s=]+/ } split /\s*\n+\s*/, <<'END_OVERRIDES' };

libwww-perl    = perl-libwww
mod_perl       = perl-modperl
glade-perl-two = perl-glade-two
aceperl        = perl-ace

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
Readonly my $PKGBUILD_TEMPL => <<'END_TEMPL';
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
source='[% srcurl %]'
md5sums=('[% md5sum %]')

# Needed if the Makefile tries to run the module after
# "installing".  This normally still fails, anyways...
#export PERL5LIB="${PERL5LIB}:$pkgdir/usr/lib/perl5/vendor_perl"

build() {
[% IF is_makemaker %]
  ( cd "${srcdir}/[% distdir %]"
    perl Makefile.PL INSTALLDIRS=vendor &&
    make &&
[% skiptest_comment %]   PERL_MM_USE_DEFAULT=1 make test &&
    make DESTDIR="${pkgdir}/" install
  ) || return 1;
[% FI %]
[% IF is_modulebuild %]
  ( cd "${srcdir}/[% distdir %]"
    perl Build.PL --installdirs=vendor --destdir="$pkgdir" &&
    ./Build &&
[% skiptest_comment %]   ./Build test &&
    ./Build install
  ) || return 1;
[% FI %]

  find "$pkgdir" -name .packlist -delete
  find "$pkgdir" -name perllocal.pod -delete
}
END_TEMPL

####
#### CLASS GLOBALS
####

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
        if (/ ^ $cfg_var_match = "? (.*?) "? $ /xmso) {
            ${$cfg_vars{$1}} = $2;
        }
    }
    close $mkpkgconf or error "close on makepkg.conf: $!";
}

####
#### PUBLIC CPANPLUS::Dist::Base Interface
####

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

sub init
{
    my $self = shift;

    $self->status->mk_accessors( qw{ pkgname  pkgver  pkgbase pkgdesc
                                     pkgurl   pkgsize pkgarch
                                     builddir destdir } );
    return 1;
}

sub prepare
{
    my ($self, %opts) = (shift, @_);

    my $status   = $self->status;                # Private hash
    my $module   = $self->parent;                # CPANPLUS::Module
    my $intern   = $module->parent;              # CPANPLUS::Internals
    my $conf     = $intern->configure_object;    # CPANPLUS::Configure
    my $distcpan = $module->status->dist_cpan;   # CPANPLUS::Dist::MM or
                                                 # CPANPLUS::Dist::Build

    $self->_prepare_status;

    $status->prepared(0);

    # Create a directory for the new package
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

    return $self->SUPER::prepare(@_);
}

sub create
{
    my ($self, %opts) = (shift, @_);

    my $status   = $self->status;                # Private hash
    my $module   = $self->parent;                # CPANPLUS::Module
    my $intern   = $module->parent;              # CPANPLUS::Internals
    my $conf     = $intern->configure_object;    # CPANPLUS::Configure
    my $distcpan = $module->status->dist_cpan;   # CPANPLUS::Dist::MM or
                                                 # CPANPLUS::Dist::Build

    # Use CPANPLUS::Dist::Base to make packages for pre-requisites...

    my @ok_resolve_args = qw/ verbose target force prereq_build /;
    my %resolve_args = map { exists $opts{$_}  ?
                             ($_ => $opts{$_}) : () } @ok_resolve_args;

    $distcpan->_resolve_prereqs( %resolve_args,
                                 'format'  => ref $self,
                                 'prereqs' => $module->status->prereqs );

    # Prepare our file name paths for pkgfile and source tarball...
    my $pkgfile = join '-', ("${\$status->pkgname}",
                             "${\$status->pkgver}-1",
                             "${\$status->pkgarch}.pkg.tar.gz");

    my $srcfile_fqp = $status->pkgbase . '/' . $module->package;
    my $pkgfile_fqp = $status->pkgbase . "/$pkgfile";

    # Prepare our 'makepkg' package building directory,
    # namely the PKGBUILD and source tarball files...
    if ( ! -e $srcfile_fqp ) {
        my $tarball_fqp = $module->_status->fetch;
        link $tarball_fqp, $srcfile_fqp
            or error "Failed to create link to $tarball_fqp: $OS_ERROR";
    }

    $self->_create_pkgbuild( skiptest => $opts{skiptest} );

    # Starting your engines!
    chdir $status->pkgbase or die "chdir: $OS_ERROR";
    my $makepkg_cmd = join ' ', ( 'makepkg',
                                  #'-m',
                                  ( $opts{force}    ? '-f'         : () ),
                                  ( !$opts{verbose} ? '>/dev/null' : () )
                                 );
    system $makepkg_cmd;

    if ($?) {
        error ( $? & 127
                ? sprintf "makepkg failed with signal %d\n",        $? & 127
                : sprintf "makepkg returned abnormal status: %d\n", $? >> 8 );
        return 0;
    }

    my $destfile_fqp = catfile( $status->destdir, $pkgfile );
    if ( ! rename $pkgfile_fqp, $destfile_fqp ) {
        error "failed to move $pkgfile to $destfile_fqp: $OS_ERROR";
        return 0;
    }

    $status->dist($destfile_fqp);
    return $status->created(1);
}

sub install
{
    my ($self, %opts) = (shift, @_);

    my $status   = $self->status;             # Private hash
    my $module   = $self->parent;             # CPANPLUS::Module
    my $intern   = $module->parent;           # CPANPLUS::Internals
    my $conf     = $intern->configure_object; # CPANPLUS::Configure

    my $sudocmd = $conf->get_program('sudo');
    if( $EFFECTIVE_USER_ID != $ROOT_USER_ID ) {
        if( $sudocmd ) {
            system "sudo pacman -U ${\$status->dist}";
        }
        else {
            error $NONROOT_WARNING;
            return 0;
        }
    }
    else { system "pacman -U ${\$status->dist}"; }

    if ($?) {
        error ( $? & 127
                ? sprintf "pacman failed with signal %d",        $? & 127
                : sprintf "pacman returned abnormal status: %d", $?>>8   
               );
        return 0;
    }

    return $status->installed(1);
}


####
#### PRIVATE INSTANCE METHODS
####

#---INSTANCE METHOD---
# Usage   : my $pkgname = $self->_translate_pkgname($dist_name);
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

    $distname = lc $distname;
    if ( $distname !~ / (?: \A perl- ) | (?: -perl \z ) /xms ) {
        $distname = "perl-$distname";
    }

    return $distname;
}

#---INSTANCE METHOD---
# Purpose  : Convert CPAN a module's distribution version into our more
#            restrictive pacman package version number.
#---------------------
sub _translate_version
{
    die "Invalid arguments to _translate_version method" if @_ != 2;
    my ($self, $version) = @_;

    # Remove anything other than numbers and decimal points.
    $version =~ tr/0-9.//c;
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
    my ($self) = @_;

    my %pkgdeps;

    my $module  = $self->parent;
    my $backend = $module->parent;
    my $prereqs = $module->status->prereqs;

    CPAN_DEP_LOOP:
    for my $modname (keys %{$prereqs}) {
        my $depver = $prereqs->{$modname};

        # Sometimes a perl version is given as a prerequisite
        # XXX Seems filtered out of prereqs() hash beforehand..?
        if ( $modname eq 'perl' ) {
            $pkgdeps{perl} = $depver;
            next CPAN_DEP_LOOP;
        }

        # Ignore modules included with this version of perl...
        next CPAN_DEP_LOOP
            if ( exists $Module::CoreList::version{0+$]}->{$modname} );

        # Use a module's _distribution_ name (tarball filename) instead
        # of just the module name because this corresponds easier to a
        # pacman package file...

        my $modobj  = $backend->parse_module( module => $modname );
        my $pkgname = $self->_translate_name( $modobj->package_name );

        $pkgdeps{$pkgname} = $self->_translate_version($depver);
    }

    # Default to requiring the current perl version used to compile
    # the module if there is no explicit perl version required...
    $pkgdeps{perl} ||= sprintf '%vd', $PERL_VERSION;

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
# Comments : We search through the META.yml file and then the README file.
#---------------------
#TODO# This should also look in the module source code's POD.
sub _prepare_pkgdesc
{
    my ($self) = @_;
    my ($status, $module, $pkgdesc) = ($self->status, $self->parent);

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

    # Next, try to find it in in the README file
    open my $readme, '<', $module->status->extract . '/README'
        or return $status->pkgdesc(q{});
#   error( "Could not open README to get pkgdesc: $!" ), return undef;

    my $modname = $module->name;
    while ( <$readme> ) {
        chomp;
        if ( (/^NAME/ ... /^[A-Z]+/) &&
             (($pkgdesc) = / ^ \s* ${modname} [\s\-]+ (.+) $ /oxms) ) {
            close $readme;
            return $status->pkgdesc($pkgdesc);
        }
    }
    close $readme;

    return $status->pkgdesc(q{});
}

#---INSTANCE METHOD---
# Usage    : $self->_prepare_status()
# Purpose  : Prepares all the package-specific accessors in our $self->status
#            accessor object (of the class Object::Accessor).
# Postcond : Accessors assigned to: pkgname pkgver pkgbase pkgarch
# Returns  : The object's status accessor.
#---------------------
sub _prepare_status
{
    my $self     = shift;
    my $status   = $self->status; # Private hash
    my $module   = $self->parent; # CPANPLUS::Module
    my $conf     = $module->parent->configure_object;

    my $our_base = catdir( $conf->get_conf('base'),
                           ( sprintf "%vd", $PERL_VERSION ),
                           'pacman' );

    $status->destdir( $PKGDEST || catdir( $our_base, 'pkg' ) );

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
# Usage    : my $pkgurl = $self->_get_disturl
# Purpose  : Creates a nice, version agnostic homepage URL for the distribution.
# Returns  : URL to the distribution's web page on CPAN.
#---------------------
sub _get_disturl
{
    my $self   = shift;
    my $module = $self->parent;

    my $distname  = $module->name;
    $distname     =~ tr/:/-/s;
    return join '/', $CPANURL, 'dist', $distname;
}

#---INSTANCE METHOD---
# Usage    : my $srcurl = $self->_get_srcurl()
# Purpose  : Generates the standard cpan download link for the source tarball.
# Returns  : URL to the distribution's tarball on CPAN.
#---------------------
sub _get_srcurl
{
    my ($self) = @_;
    my $module = $self->parent;

    return join '/', $CPANURL, $module->path, $module->package;
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

    my $tarball_fqp = $self->status->pkgbase . '/' . $module->package;
    open my $distfile, '<', $tarball_fqp
        or die "failed to get md5 of $tarball_fqp: $OS_ERROR";

    my $md5 = Digest::MD5->new;
    $md5->addfile($distfile);
    close $distfile;

    return $md5->hexdigest;
}

#---INSTANCE METHOD---
# Usage    : $self->_create_pkgbuild()
# Purpose  : Creates a PKGBUILD file in the package's build directory.
# Precond  : 1. You must first call prepare on the SUPER class in order
#               to populate the pre-requisites.
#            2. _prepare_status must be called before this method
# Throws   : unknown installer type: '...'
#            failed to write PKGBUILD: ...
# Returns  : Nothing.
#---------------------
sub _create_pkgbuild
{
    my $self = shift;
    my %opts = @_;

    my $status  = $self->status;
    my $module  = $self->parent;
    my $conf    = $module->parent->configure_object;

    my $pkgdeps = $self->_translate_cpan_deps;

    my $pkgdesc = $status->pkgdesc;
    my $fqpath  = catfile( $status->pkgbase, 'PKGBUILD' );

    my $extdir  = $module->package;
    $extdir     =~ s/ [.] ${\$module->package_extension} \z //xms;

    $pkgdesc    =~ s/ " / \\" /gxms; # Quote our package desc for bash.

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

    my $pkgbuild_text = $self->_process_template( $PKGBUILD_TEMPL,
                                                  $templ_vars );

    open my $pkgbuild_file, '>', $fqpath
        or die "failed to write PKGBUILD: $OS_ERROR";
    print $pkgbuild_file $pkgbuild_text;
    close $pkgbuild_file
        or die "failed to write PKGBUILD: $OS_ERROR";

    return;
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

1; # End of CPANPLUS::Dist::Arch
