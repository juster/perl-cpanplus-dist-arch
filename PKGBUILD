# -*- Mode: shell-script; sh-basic-offset: 2 -*-
# Contributor: Justin Davis <jrcd83@gmail.com>
pkgname='perl-cpanplus-dist-arch-git'
pkgver='20100512'
pkgrel='1'
pkgdesc='Newest developer release for CPANPLUS::Dist::Arch'
arch=('any')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
makedepends=('perl-test-pod-coverage' 'perl-test-pod')
depends=('perl')
provides=('perl-cpanplus-dist-arch')
url='http://github.com/juster/perl-cpanplus-dist-arch'
md5sums=()
source=()

_gitroot='git://github.com/juster/perl-cpanplus-dist-arch.git'
_gitname=${BRANCH:-'master'}

build() {
  DIST_DIR="${srcdir}/${pkgname}"
  msg 'Creating CPANPLUS::Dist::Arch developer package...'

  if [ -d "$DIST_DIR" ] ; then
    warning 'Repository directory already exists!'
    msg2 'Attempting to pull from repo...'
    cd "$DIST_DIR"
    git pull
  else
    msg2 "Cloning $_gitroot repository..."
    git clone "$_gitroot" "$DIST_DIR"
    cd "$DIST_DIR"
  fi

  msg2 "Checking out the $_gitname branch..."
  git checkout "$_gitname"
  if [ "$?" -ne 0 ] ; then
    error "Failed to checkout the $_gitname branch... aborting."
    exit 1
  fi

  export PERL_MM_OPT="INSTALLDIRS=vendor DESTDIR=$pkgdir"  \
    PERL_MB_OPT="--installdirs vendor --destdir '$pkgdir'" \
    MODULEBUILDRC='/dev/null' TEST_RELEASE=1

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
