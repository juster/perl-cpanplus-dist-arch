package CPANPLUS::Dist::Arch;

use warnings;
use strict;
use English '-no_match_vars';

use base 'CPANPLUS::Dist::Base';

use CPANPLUS::Error;
use Module::CoreList;
use File::Path       qw(mkpath);
use File::Copy       qw(copy);
use File::stat       qw(stat);
use IPC::Cmd         qw(run can_run);
use Readonly;
use Carp             qw(croak carp);

use Data::Dumper;

our $VERSION = '0.2';

####
#### CLASS CONSTANTS AND GLOBALS
####

Readonly my $MKPKGCONF_FQN => '/etc/makepkg.conf';
Readonly my $CPANURL       => 'http://search.cpan.org';
Readonly my $ROOT_USER_ID  => 0;

Readonly my $NONROOT_WARNING => <<'END_MSG';
In order to install packages as a non-root user (highly recommended)
you must have a sudo-like command specified in your CPANPLUS
configuration.
END_MSG

Readonly my $MMAKER_FMT    => <<'END_BUILD';
  ( cd "${srcdir}/%s" 
    perl Makefile.PL INSTALLDIRS=vendor &&
    make &&
%s   PERL_MM_USE_DEFAULT=1 make test &&
    make DESTDIR="${pkgdir}/" install
  ) || return 1;
END_BUILD

Readonly my $BUILD_FMT     => <<'END_BUILD';
  ( cd "${srcdir}/%s"
    perl Build.pl --installdirs vendor --destdir $pkgdir
  ) || return 1;
END_BUILD

our ($PKGBUILD, $PKGDEST, $PACKAGER, $LICENSE);

sub BEGIN
{
	# Set defaults
	$PKGBUILD = sprintf "$ENV{HOME}/.cpanplus/%vd/pacman/build", $PERL_VERSION;
	$PKGDEST  = sprintf "$ENV{HOME}/.cpanplus/%vd/pacman/pkg",   $PERL_VERSION;
	$PACKAGER = 'Anonymous';

	# Read makepkg.conf to see if there are system-wide settings
	if ( ! open my $mkpkgconf, '<', $MKPKGCONF_FQN ) {
        carp "Could not read $MKPKGCONF_FQN: $!";
        return;
    }

    my %cfg_vars = ( 'PKGDEST'  => \$PKGDEST,
                     'PACKAGER' => \$PACKAGER );

	while (<$mkpkgconf>) {
        for my $var_name (keys %cfg_vars) {
            if (/ ^ $var_name = "? (.*) "? $ /xms) {
                ${$cfg_vars{$var_name}} = $1;
            }
        }
	}
	close $mkpkgconf;

    return;
}


####
#### CPANPLUS::Dist::Base Methods
####

##
## my $bool = format_available( $self )
##
## Return true if we have the tools needed to make a pacman package.
## Return false if we don't think so.
##
#

sub format_available
{
	my @progs = qw/ makepkg pacman /;
	foreach my $prog (@progs) {
		if ( ! can_run($prog) ) {
			error "CPANPLUS::Dist::Arch needs $prog to work properly";
			return 0;
		}
	}
	return 1;
}

##
## my $bool = init( $self )
##
## Initializes the object internals to get things started
## Return true if ok, false on error.
##
#

sub init
{
	my $self = shift;

	$self->status->mk_accessors( qw{ pkgname pkgver pkgbase pkgdesc
                                     pkgdir  pkgurl pkgsize pkgarch } );
	return 1;
}

##
## my $bool = prepare( $self, %options )
##
## Prepares the files and directories we will need to build a package
## inside.  Also prepares any data we need on a per-object basis.
##
## Return true if ok, false on error.  Sets $self->status->prepare to
## true or false on success or failure.
##
#

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

		mkpath $dir or die "failed to create directory '$dir': $!";

		if ( $opts{'verbose'} ) { msg "Created directory $dir" }
	}

	return $self->SUPER::prepare(@_);
}

#
# my $bool = create( $self, %options );
#

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
	my @ok_args = qw{ format verbose target force prereq_build };
	my %resolve_args;
	@resolve_args{@ok_args} = @opts{@ok_args};
	$self->_resolve_prereqs( %resolve_args,
							 'format' => ref $self,
							 'target' => 'install',
							 'prereqs' => $module->status->prereqs );

    # Prepare our file name paths for pkgfile and source tarball...
 	my $pkgfile = join '', ("${\$status->pkgname}-",
                            "${\$status->pkgver}-1-",
                            "${\$status->pkgarch}.pkg.tar.gz");

	my $srcfile_fqp = $status->pkgbase . '/' . $module->package;
	my $pkgfile_fqp = $status->pkgbase . "/$pkgfile";

    # Prepare our 'makepkg' package building directory...
	$self->_create_pkgbuild(skiptest => $opts{skiptest}) or return 0;
	if ( ! -e $srcfile_fqp ) {
        my $tarball_fqp = $module->_status->fetch;
        link $tarball_fqp, $srcfile_fqp
            or error "Failed to create link to $tarball_fqp: $!";
	}

    # Change to the building directory and call makepkg...
	chdir $status->pkgbase or die "chdir: $!";
	my $makepkg_cmd = join ' ', ( 'makepkg -m',
                                  ( $opts{force}    ? '-f'         : () ),
                                  ( !$opts{verbose} ? '>/dev/null' : () ) );
	system $makepkg_cmd;

	if($?) {
        error ( $? & 127
                ? sprintf "makepkg failed with signal %d\n", $? & 127
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
	my ($self, %opts) = (shift, $@);

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


#--- INSTANCE METHOD ---
# Usage   : my $pkgname = $arch->_pkg_name($cpanname);
# Purpose : Converts a module name to an Archlinux perl package name.
# Params  : $cpanname - The cpan module name (ex: Acme::Drunk).
# Returns : The Archlinux perl package name (ex: perl-acme-drunk).
#-----------------------

sub _pkg_name
{
	my ($self, $cpanname) = @_;
	$cpanname = lc $cpanname;
	$cpanname =~ tr/:/-/s;
	return 'perl-'.$cpanname;
}

#--- INSTANCE METHOD ---
# Usage    : $pkgdesc = $self->_prepare_pkgdesc();
# Purpose  : Tries to find a module's "abstract" short description for
#            use as a package description.
# Postcond : Sets the $self->status->pkgdesc accessor to the found
#            package description.
# Returns  : The package description
# Comments : We search through the META.yml file and then the README file.
#-----------------------

sub _prepare_pkgdesc
{
	my ($self) = @_;
	my ($status, $module, $pkgdesc) = ($self->status, $self->parent);

	# First, try to find the short description in the META.yml file.
	my $metayml;
	unless( open $metayml, '<', $module->status->extract .'/META.yml' ) {
	  error "Could not open META.yml to get pkgdesc: $!";
	  goto CHECKREADME;
	}

	while ( <$metayml> ) {
	  if (/^abstract:\s*(.+)/) {
		$pkgdesc = $1;
		$pkgdesc = $1 if ($pkgdesc =~ /^'(.*)'$/);
		goto FOUNDDESC;
	  }
	}
	close $metayml;

	# Next, try to find it in in the README file
 CHECKREADME:
	open my $readme, '<', $module->status->extract . '/README' or
	error( "Could not open README to get pkgdesc: $!" ), return undef;

	my $modname = $module->name;
	while ( <$readme> ) {
		if ( /^NAME/ ... /^[A-Z]+/ &&
				 / ^\s* ${modname} [\s-] (.+) /ox ) {
			$pkgdesc = $1;
			goto FOUNDDESC;
		}
	}
	close $readme;

	return undef;

 FOUNDDESC:
#	print "[###DEBUG###] pkgdesc=$pkgdesc\n";
	return $self->status->pkgdesc($pkgdesc);
}

#--- INSTANCE METHOD ---
# Usage    : $self->_prepare_status ( );
# Purpose  : Prepares all the package-specific accessors in our $self->status
#            accessor object (of the class Object::Accessor).
# Postcond : Accessors assigned to: pkgname pkgver pkgbase pkgdir pkgarch
# Returns  : The object's status accessor.
#-----------------------

sub _prepare_status
{
	my $self     = shift;
	my $status   = $self->status;	# Private hash
	my $module   = $self->parent;	# CPANPLUS::Module

	my ($pkgver, $pkgname) = ( $module->version,
                               $self->_pkg_name($module->name) );

	my $pkgbase = "$PKGBUILD/$pkgname";
	my $pkgdir  = "$pkgbase/pkg";
	my $pkgarch = `uname -m`;
	chomp $pkgarch;

	foreach(( $pkgname, $pkgver, $pkgbase, $pkgdir, $pkgarch )) {
		die "A package variable is invalid" unless(defined $_);
	}

	$status->pkgname( $pkgname );
	$status->pkgver ( $pkgver  );
	$status->pkgbase( $pkgbase );
	$status->pkgdir ( $pkgdir  );
	$status->pkgarch( $pkgarch );

	$self->_prepare_pkgdesc;

	return $status;
}

#--- INSTANCE METHOD ---
# Usage    : my $pkgurl = $self->_create_dist_url
# Purpose  : Creates a nice, version agnostic homepage URL for the distribution.
# Returns  : URL to the author's dist page on CPAN.
#-----------------------

sub _create_dist_url
{
	my $self   = shift;
	my $module = $self->parent;

	my $modname  = $module->name;
	my $authorid = lc $module->author->cpanid;
	$modname =~ tr/:/-/s;
	return "http://search.cpan.org/~${authorid}/${modname}";
}

#--- INSTANCE METHOD ---
# Usage    : my $srcurl = $self->_create_src_url()
# Purpose  : Generates the standard cpan download link for the source tarball.
# Returns  : URL to the distribution's tarball.
#-----------------------

sub _create_src_url
{
	my ($self) = @_;
	my $module = $self->parent;

	my $path   = $module->path;
	my $file   = $module->package;
	return "${CPANURL}/${path}/${file}";
}

#--- INSTANCE METHOD ---
# Usage    : my $deps_str = $self->_create_pkgbuild_deps()
# Purpose  : Convert CPAN prerequisites into package dependencies
# Returns  : String to be appended after 'depends=' in PKGBUILD file.
#-----------------------

sub _create_pkgbuild_deps
{
    my ($self) = @_;

	my @pkgdeps;

    my $module  = $self->parent;
	my $prereqs = $module->status->prereqs;

	for my $modname (keys %{$prereqs}) {
        my $depver = $prereqs->{$modname};

		# Sometimes a perl version is given as a prerequisite
		# XXX Seems filtered out of prereqs() hash beforehand..?
		if( $modname eq 'perl' ) {
			push @pkgdeps, "perl>=$depver";
			next;
		}

        # Ignore modules included with perl...
		next if exists $Module::CoreList::version{$PERL_VERSION}->{$modname} ;

		my $pkgdep = $self->_pkg_name($modname);
		if ($depver) {
			$pkgdep .= ">=$depver";
		}
		push @pkgdeps, qq{'$pkgdep'};
	}

	return join ' ', @pkgdeps;
}

#--- INSTANCE METHOD ---
# Usage    : $self->_create_pkgbuild()
# Purpose  : Creates a PKGBUILD file in the package's build directory.
# Precond  : 1. You must first call prepare on the SUPER class in order
#               to populate the pre-requisites.
#            2. _prepare_status must be called before this method
# Throws   : unknown installer type: '...'
#            failed to write PKGBUILD: ...
# Returns  : Nothing.
#-----------------------

sub _create_pkgbuild
{
	my $self = shift;
	my %opts = @_;

	my $status  = $self->status;
    my $module  = $self->parent;
	my $conf    = $module->parent->configure_object;

	my $disturl = $self->_create_dist_url;
    my $srcurl  = $self->_create_src_url;
    my $pkgdeps = $self->_create_pkgbuild_deps;

	my $pkgdesc = $status->pkgdesc;
	my $fqpath  = $status->pkgbase . '/PKGBUILD';

    # Quote our package desc for bash.
    # Don't use 's cuz you can't escape them in a bash script.
	$pkgdesc =~ s{["]}{\\$1};

	my $pkgbuild_start = <<"END_PKGBUILD";
# Contributor: $PACKAGER
# Generator  : CPANPLUS::Dist::Arch $VERSION
pkgname='${\$status->pkgname}'
pkgver='${\$status->pkgver}'
pkgrel='1'
pkgdesc="$pkgdesc"
arch=('i686' 'x86_64')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=($depends)
url='$disturl'
source='$srcurl'

END_PKGBUILD

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
        $pkgbuild_buildsub .= sprintf $BUILD_FMT, $extdir;
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
    print $pkgbuild, $pkgbuild_start, $pkgbuild_buildsub;
	close $pkgbuild;

	return;
}

1;
