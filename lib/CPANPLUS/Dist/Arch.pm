package CPANPLUS::Dist::Arch;

use warnings;
use strict;
use English '-no_match_vars';

use base 'CPANPLUS::Dist::Base';

use CPANPLUS::Error;
use Module::CoreList;
use Digest::MD5;
use File::Path       qw(mkpath);
use File::Copy       qw(copy);
use File::stat       qw(stat);
use IPC::Cmd         qw(run can_run);
use Carp             qw(croak carp);
use Readonly;

our $VERSION = '0.01';

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

# Crude templates for our PKGBUILD script:
Readonly my $MMAKER_FMT    => <<'END_BASH';
  ( cd "${srcdir}/%s" 
    perl Makefile.PL INSTALLDIRS=vendor &&
    make &&
%s   PERL_MM_USE_DEFAULT=1 make test &&
    make DESTDIR="${pkgdir}/" install
  ) || return 1;
END_BASH

Readonly my $MODBUILD_FMT  => <<'END_BASH';
  ( cd "${srcdir}/%s"
    perl Build.pl --installdirs vendor --destdir $pkgdir
  ) || return 1;
END_BASH

####
#### CLASS GLOBALS (I should probably move these to a private hash)
####

our ($PKGBUILD, $PKGDEST, $PACKAGER, $LICENSE);

$PKGBUILD = "$ENV{HOME}/.cpanplus/makepkg/build";
$PKGDEST  = "$ENV{HOME}/.cpanplus/makepkg/pkg";
$PACKAGER = 'Anonymous';

READ_CONF:
{
	# Read makepkg.conf to see if there are system-wide settings
    my $mkpkgconf;
	if ( ! open $mkpkgconf, '<', $MKPKGCONF_FQP ) {
        carp "Could not read $MKPKGCONF_FQP: $!";
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
	close $mkpkgconf;
}

####
#### PUBLIC CPANPLUS::Dist::Base Interface
####

sub format_available
{
	for my $prog ( qw/ makepkg pacman / ) {
		if ( ! can_run($prog) ) {
			error "CPANPLUS::Dist::Arch needs $prog to work properly";
			return 0;
		}
	}
	return 1;
}

sub init
{
	my $self = shift;

	$self->status->mk_accessors( qw{ pkgname pkgver pkgbase pkgdesc
                                     pkgdir  pkgurl pkgsize pkgarch } );
	return 1;
}

sub prepare
{
	my ($self, %opts) = (shift, @_);

	my $status   = $self->status;				 # Private hash
	my $module   = $self->parent;				 # CPANPLUS::Module
	my $intern   = $module->parent;				 # CPANPLUS::Internals
	my $conf     = $intern->configure_object;	 # CPANPLUS::Configure
	my $distcpan = $module->status->dist_cpan;	 # CPANPLUS::Dist::MM or
	                                             # CPANPLUS::Dist::Build

	$self->_prepare_status;

    $status->prepared(0);

	# Create a directory for the new package
	for my $dir ( $status->pkgbase, $PKGDEST ) {
		if ( -e $dir ) {
			die "$dir exists but is not a directory!" if ( ! -d _ );
			die "$dir exists but is read-only!"       if ( ! -w _ );
		}
        else {
            mkpath $dir or die "failed to create directory '$dir': $!";
            if ( $opts{'verbose'} ) { msg "Created directory $dir" }
        }
	}

	return $self->SUPER::prepare(@_);
}

sub create
{
	my ($self, %opts) = (shift, @_);

	my $status   = $self->status;				 # Private hash
	my $module   = $self->parent;				 # CPANPLUS::Module
	my $intern   = $module->parent;				 # CPANPLUS::Internals
	my $conf     = $intern->configure_object;	 # CPANPLUS::Configure
	my $distcpan = $module->status->dist_cpan;	 # CPANPLUS::Dist::MM or
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
            or error "Failed to create link to $tarball_fqp: $!";
	}

	$self->_create_pkgbuild( skiptest => $opts{skiptest} );


    # Change to the building directory and call makepkg...
	chdir $status->pkgbase or die "chdir: $!";
	my $makepkg_cmd = join ' ', ( 'makepkg',
                                  '-m',
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

	if ( ! rename $pkgfile_fqp, "$PKGDEST/$pkgfile" ) {
		error "failed to move $pkgfile to $PKGDEST: $!";
		return 0;
	}

	$status->dist("$PKGDEST/$pkgfile");

	return $self->SUPER::create(@_);
}

sub install
{
	my ($self, %opts) = (shift, @_);

	my $status   = $self->status;			  # Private hash
	my $module   = $self->parent;			  # CPANPLUS::Module
	my $intern   = $module->parent;			  # CPANPLUS::Internals
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
                ? sprintf "pacman failed with signal %d", $? & 127
                : sprintf "pacman returned abnormal status: %d", $?>>8 );
		return 0;
	}

	return $status->installed(1);
}


####
#### PRIVATE INSTANCE METHODS
####

#---INSTANCE METHOD---
# Usage   : my $pkgname = $self->_convert_pkgname($module_object);
# Purpose : Converts a module's dist[ribution tarball] name to an
#           Archlinux style perl package name.
# Params  : $cpanname - The cpan module name (ex: Acme::Drunk).
# Returns : The Archlinux perl package name (ex: perl-acme-drunk).
#---------------------

sub _convert_pkgname
{
    my ($self, $module) = @_;

    my $distext  = $module->package_extension;
    my $distname = $module->package;
    $distname = lc $distname;
    $distname =~ s/ - [\d.]+ [.] $distext $ //xms;
    $distname = "perl-$distname" if $distname !~ / ^ perl- /xms;

    return $distname;
}

#---INSTANCE METHOD---
# Usage    : $pkgdesc = $self->_prepare_pkgdesc();
# Purpose  : Tries to find a module's "abstract" short description for
#            use as a package description.
# Postcond : Sets the $self->status->pkgdesc accessor to the found
#            package description.
# Returns  : The package description
# Comments : We search through the META.yml file and then the README file.
#---------------------

#TODO# This is REALLY funky.  Need to redo this and get rid of goto's
#TODO# This should also look in the module source code's POD.

sub _prepare_pkgdesc
{
	my ($self) = @_;
	my ($status, $module, $pkgdesc) = ($self->status, $self->parent);

	# First, try to find the short description in the META.yml file.
    METAYML:
    {
        my $metayml;
        unless ( open $metayml, '<', $module->status->extract .'/META.yml' ) {
            error "Could not open META.yml to get pkgdesc: $!";
            last METAYML;
        }

        while ( <$metayml> ) {
            if (/^abstract:\s*(.+)/) {
                $pkgdesc = $1;
                $pkgdesc = $1 if ( $pkgdesc =~ /^'(.*)'$/ );
                close $metayml;
                goto FOUNDDESC;
            }
        }
        close $metayml;
    }

	# Next, try to find it in in the README file
 CHECKREADME:
	open my $readme, '<', $module->status->extract . '/README' or
	error( "Could not open README to get pkgdesc: $!" ), return undef;

	my $modname = $module->name;
	while ( <$readme> ) {
		if ( /^NAME/ ... /^[A-Z]+/ &&
             / ^\s* ${modname} [\s-]+ (.+) $ /oxms ) {
			$pkgdesc = $1;
            close $readme;
			goto FOUNDDESC;
		}
	}
	close $readme;

	return $self->status->pkgdesc(q{});

 FOUNDDESC:
#	print "[###DEBUG###] pkgdesc=$pkgdesc\n";
	return $self->status->pkgdesc($pkgdesc);
}

#---INSTANCE METHOD---
# Usage    : $self->_prepare_status();
# Purpose  : Prepares all the package-specific accessors in our $self->status
#            accessor object (of the class Object::Accessor).
# Postcond : Accessors assigned to: pkgname pkgver pkgbase pkgdir pkgarch
# Returns  : The object's status accessor.
#---------------------

sub _prepare_status
{
	my $self     = shift;
	my $status   = $self->status; # Private hash
	my $module   = $self->parent; # CPANPLUS::Module

	my ($pkgver, $pkgname) = ( $module->version,
                               $self->_convert_pkgname($module) );

	my $pkgbase = "$PKGBUILD/$pkgname";
	my $pkgdir  = "$pkgbase/pkg";
	my $pkgarch = `uname -m`;
	chomp $pkgarch;

	foreach ( $pkgname, $pkgver, $pkgbase, $pkgdir, $pkgarch ) {
		die "A package variable is invalid" unless defined;
	}

	$status->pkgname($pkgname);
	$status->pkgver ($pkgver );
	$status->pkgbase($pkgbase);
	$status->pkgdir ($pkgdir );
	$status->pkgarch($pkgarch);

	$self->_prepare_pkgdesc;

	return $status;
}

#---INSTANCE METHOD---
# Usage    : my $pkgurl = $self->_get_disturl
# Purpose  : Creates a nice, version agnostic homepage URL for the distribution.
# Returns  : URL to the author's dist page on CPAN.
#---------------------

sub _get_disturl
{
	my $self   = shift;
	my $module = $self->parent;

	my $modname  = $module->name;
	my $authorid = lc $module->author->cpanid;
	$modname =~ tr/:/-/s;
	return "http://search.cpan.org/~${authorid}/${modname}";
}

#---INSTANCE METHOD---
# Usage    : my $srcurl = $self->_get_srcurl()
# Purpose  : Generates the standard cpan download link for the source tarball.
# Returns  : URL to the distribution's tarball.
#---------------------

sub _get_srcurl
{
	my ($self) = @_;
	my $module = $self->parent;

	my $path   = $module->path;
	my $file   = $module->package;
	return join '/', ($CPANURL, $path, $file);
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
# Usage    : my $deps_str = $self->_create_pkgbuild_deps()
# Purpose  : Convert CPAN prerequisites into package dependencies
# Returns  : String to be appended after 'depends=' in PKGBUILD file.
#---------------------

sub _convert_pkgbuild_deps
{
    my ($self) = @_;

	my %pkgdeps;

    my $module  = $self->parent;
    my $backend = $module->parent;
	my $prereqs = $module->status->prereqs;

	for my $modname (keys %{$prereqs}) {
        my $depver = $prereqs->{$modname};

		# Sometimes a perl version is given as a prerequisite
		# XXX Seems filtered out of prereqs() hash beforehand..?
		if ( $modname eq 'perl' ) {
            $pkgdeps{perl} = $depver;
			next;
		}

        # Ignore modules included with perl...
		next if exists $Module::CoreList::version{0+$]}->{$modname} ;

        # Use a module's _distribution_ name (tarball filename) instead
        # of just the module name because this corresponds easier to a
        # pacman package file...

        my $modobj = $backend->parse_module( module => $modname );
        my $pkgname = $self->_convert_pkgname($modobj);

        $pkgdeps{$pkgname} = $depver;
	}

	return join ' ',
        map { defined $pkgdeps{$_} ? qq{'${_}>=$pkgdeps{$_}'} : qq{'$_'} }
            sort keys %pkgdeps;
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

	my $disturl = $self->_get_disturl;
    my $srcurl  = $self->_get_srcurl;
    my $md5sum  = $self->_calc_tarballmd5;
    my $pkgdeps = $self->_convert_pkgbuild_deps;

	my $pkgdesc = $status->pkgdesc;
	my $fqpath  = $status->pkgbase . '/PKGBUILD';

    # Quote our package desc for bash.
    # Don't use 's cuz you can't escape them in a bash script.
	$pkgdesc =~ s{ ( ["] ) }{ \\$1 }gxms;

	my $pkgbuild_start = <<"END_BASH";
# Contributor: $PACKAGER
# Generator  : CPANPLUS::Dist::Arch $VERSION
pkgname='${\$status->pkgname}'
pkgver='${\$status->pkgver}'
pkgrel='1'
pkgdesc="$pkgdesc"
arch=('i686' 'x86_64')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=($pkgdeps)
url='$disturl'
source='$srcurl'
md5sums=('$md5sum')

END_BASH

	my $dist_type         = $module->status->installer_type;
    my $pkgbuild_buildsub = "build() {\n";

	my $extdir = $module->package;
    $extdir    =~ s/ [.] ${\$module->package_extension} $ //xms;

	if ( $dist_type eq 'CPANPLUS::Dist::MM' ) {
		# Comment out the 'make test' command if --skiptest is given on
		# the command line...
        $pkgbuild_buildsub .= sprintf $MMAKER_FMT, $extdir,
            ( $conf->get_conf('skiptest') ? '#' : ' ' );
	}
	elsif ( $dist_type eq 'CPANPLUS::Dist::Build' ) {
        $pkgbuild_buildsub .= sprintf $MODBUILD_FMT, $extdir;
	}
	else {
        die "unknown Perl module installer type: '$dist_type'";
	}

	$pkgbuild_buildsub .= <<'END_BASH';
  find "$pkgdir" -name .packlist -delete
  find "$pkgdir" -name perllocal.pod -delete
}

END_BASH

	open my $pkgbuild, '>', $fqpath or die "failed to write PKGBUILD: $!";
    print $pkgbuild $pkgbuild_start, $pkgbuild_buildsub;
	close $pkgbuild;

	return;
}

1; # End of CPANPLUS::Dist::Arch

=head1 NAME

CPANPLUS::Dist::Arch - Creates Archlinux packages from Perl's CPAN repository.

=head1 VERSION

Version 0.01 -- First Release

=head1 SYNOPSIS

This module is not meant to be used directly.  Instead you should use
it through the cpan2dist utility that is included with CPANPLUS.

  $ cpan2dist --verbose --format CPANPLUS::Dist::Arch DBIx::Class

  $ cpan2dist --format CPANPLUS::Dist DBIx::Class

This lengthly command line can be shortened by specifying
CPANPLUS::Dist::Arch as the default 'Dist' type to use in CPANPLUS's
configuration.

  $ cpanp

  ... CPANPLUS's startup output here ...

  CPAN Terminal> s conf dist_type CPANPLUS::Dist::Arch

  Key 'dist_type' was set to 'CPANPLUS::Dist::Arch'
  CPAN Terminal> s save

  Configuration successfully saved to CPANPLUS::Config::User
      (/home/justin/.cpanplus/lib/CPANPLUS/Config/User.pm)
  CPAN Terminal> q

  Exiting CPANPLUS shell

  $ cpan2dist DBIx::Class

  $ cpan2dist --install DBIx::Class

Or you can edit the User.pm file mentioned above manually (replacing
my name with yours, of course!).

=head1 WHERES THE PACKAGE?

Packages are stored under the user's home directory, (the HOME
environment variable) under the .cpanplus directory.  Two seperate
directories are created for building packages and for storing the
resulting package file.

  Build Directory   : C<$HOME/.cpanplus/makepkg/build>
  Package Directory : C<$HOME/.cpanplus/makepkg/pkg>

Maybe I should copy the package to the current working directory?

=head1 COMMAND LINE OPTIONS

There are many command line options to cpan2dist.  You can find these
by typing C<cpan2dist --help> on the command line or reading the man
page with C<man cpan2dist>.  A small number of these options are
recognized by CPANPLUS::Dist::Arch.

=over

=item --verbose

This classic option allows for more verbose messages.  Otherwise you
get next to no output.  Useful for debugging and neurosis.

=item --skiptest

This will I<comment out> the tests in PKGBUILD files that are generated.
I actually think testing is a good idea and would not recommend this
unless you know what you are doing.

NOTE: This affects I<all pre-requisite module/packages> that are built
and installed; not just the module you specify.

=item --force

This passes the C<-f> flag to C<makepkg>, forcing C<makepkg> to make
or remake the package even if the package already exists.

=back

=head1 INTERFACE METHODS

See L<CPANPLUS::Dist::Base>'s documentation for a description of the
purpose of these functions.  All of these "interface" methods override
Base's default actions in order to create our packages.

These methods are called by the CPANPLUS::Backend object that controls
building new packages (ie, via the cpanp or cpan2dist commands).  You
should not call these methods directly.


=head2 format_available

  Purpose  : Checks if we have makepkg and pacman installed
  Returns  : 1 - if we have the tools needed to make a pacman package.
             0 - if we don't think so.

=head2 init

  Purpose  : Initializes our object internals to get things started
  Returns  : 1 always

=head2 prepare

  Purpose  : Prepares the files and directories we will need to build a
             package.  Also prepares any data we expect to have later,
             on a per-object basis.
  Return   : 1 if ok, 0 on error.
  Postcond : Sets $self->status->prepare to 1 or 0 on success or
             failure.

=head2 create

  Purpose  : Creates the pacman package using the 'makepkg' command.

=head2 install

  Purpose  : Installs the package file (.pkg.tar.gz) using sudo and
             pacman.
  Comments : Called automatically on pre-requisite packages and if you
             specify the --install flag

=head1 TROUBLESHOOTING

=over

=item Pacman says a required dependency just installed is missing

Pacman is much more strict with its 'package' versions than CPAN is.
pacman may rarely complain about you not having the required
version when you obviously just installed them from CPAN!

This is because CPAN module versions are wacky and can be just about
anything, while pacman's versioning is much more methodical.
CPANPLUS::Dist::Arch simply extract's CPAN's version and inserts it
into the PKGBUILD for pacman's version.  You may have to go in and
edit the PKGBUILD manually translate the version from CPAN to pacman.

(TODO: example here, I forgot what did this)

=item Package descriptions are missing

Right now this module searches in the META.xml and README file for a
package description.  The description may also be inside the module in
POD documentation.  Needless to say because there is no centralized
location for perl module descriptions, they can be iffy and hard to
find.

Again, you may have to edit the PKGBUILD if you really, really, care.
Until I add more complex handling, anyways.

=item Pre-requisites are always installed

CPANPLUS by default installs the pre-requisite modules before the
module you requested.  This module does the same only it creates an
Arch package and installs it with pacman instead.

You should be able to run pacman under sudo for this to work properly.
Or you could run cpan2dist as root, but I wouldn't recommend it.

=back

=head1 BUGS

Please report any bugs or feature requests to C<bug-cpanplus-dist-arch
at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CPANPLUS-Dist-Arch>.
I will be notified, and then you'll automatically be notified of
progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CPANPLUS::Dist::Arch


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=CPANPLUS-Dist-Arch>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CPANPLUS-Dist-Arch>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/CPANPLUS-Dist-Arch>

=item * Search CPAN

L<http://search.cpan.org/dist/CPANPLUS-Dist-Arch/>

=back

=head1 AUTHOR

Justin Davis, C<< <jrcd83 at gmail.com> >>, juster on
L<http://bbs.archlinux.org>

=head1 ACKNOWLEDGEMENTS

This module was inspired by the perl-cpanplus-pacman package and
CPANPLUS::Dist::Pacman by Firmicus which is available at
L<http://aur.archlinux.org/>.

=head1 COPYRIGHT & LICENSE

Copyright 2009 Justin Davis, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

