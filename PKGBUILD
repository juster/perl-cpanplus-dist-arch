# This PKGBUILD is for when you (I) have already cloned
# the repository with git and just want to build with the
# existing git repository.

# Contributor: Justin Davis <jrcd83@gmail.com>
pkgname='perl-cpanplus-dist-arch-devel'
pkgver='20101021'
pkgrel='1'
pkgdesc='Developer release for CPANPLUS::Dist::Arch perl module'
arch=('any')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=('perl')
provides=('perl-cpanplus-dist-arch')
conflicts=('perl-cpanplus-dist-arch')
url='http://github.com/juster/perl-cpanplus-dist-arch'

build() {
  export PERL_MM_OPT="INSTALLDIRS=vendor DESTDIR=$pkgdir"  \
    PERL_MB_OPT="--installdirs vendor --destdir '$pkgdir'" \
    MODULEBUILDRC='/dev/null' TEST_RELEASE=1

  cd "$startdir"
  msg 'Building CPANPLUS::Dist::Arch...'
  { cd "$DIST_DIR"  &&
    perl Build.PL   &&
    perl Build      &&
    msg2 'Testing CPANPLUS::Dist::Arch...' &&
    perl Build test &&
    perl Build install;
  } || return 1;

  find "$pkgdir" -name .packlist -o -name perllocal.pod -delete
}

# Local Variables:
# mode: shell-script
# sh-basic-offset: 2
# End:
