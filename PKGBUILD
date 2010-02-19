# Contributor: Justin Davis <jrcd83@gmail.com>
pkgname='perl-cpanplus-dist-arch-git'
pkgver=20100218
pkgrel=1
pkgdesc="CPANPLUS backend for building Archlinux pacman packages"
arch=('i686' 'x86_64')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=('perl')
provides=('perl-cpanplus-dist-arch')
url='http://search.cpan.org/dist/CPANPLUS-Dist-Arch'
md5sums=()
source=()

_gitroot='git://github.com/juster/perl-cpanplus-dist-arch.git'
_gitname='master'

build() {
  DIST_DIR="${srcdir}/${pkgname}"
  if [ -d $DIST_DIR ] ; then
    cd $DIST_DIR
    perl Build clean
    git pull $_gitroot $_gitname
    git checkout master
  else
    git clone $_gitroot $DIST_DIR
  fi

  export PERL_MM_USE_DEFAULT=1
  { cd "$DIST_DIR" &&
    perl Build.PL --installdirs=vendor --destdir="$pkgdir" &&
    perl Build &&
    perl Build test &&
    perl Build install;
  } || return 1;

  find "$pkgdir" -name .packlist -o -name perllocal.pod -delete
}
