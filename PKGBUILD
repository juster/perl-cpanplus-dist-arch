# Contributor: Justin Davis <jrcd83@gmail.com>
# Generator  : CPANPLUS::Dist::Arch 0.05
pkgname='perl-cpanplus-dist-arch'
pkgver='0.06'
pkgrel='1'
pkgdesc="CPANPLUS backend for building Archlinux pacman packages"
arch=('i686' 'x86_64')
license=('PerlArtistic' 'GPL')
options=('!emptydirs')
depends=('perl>=5.10.0' 'perl-readonly')
url='http://search.cpan.org/dist/CPANPLUS-Dist-Arch'
source='http://search.cpan.org/CPAN/authors/id/J/JU/JUSTER/CPANPLUS-Dist-Arch-0.06.tar.gz'
md5sums=('fad29a1a8d680e94b658d70c77fe6c46')

build() {
  export PERL_MM_USE_DEFAULT=1 
  ( cd "${srcdir}/CPANPLUS-Dist-Arch-0.06" &&
    perl Build.PL --installdirs=vendor --destdir="$pkgdir" &&
    ./Build &&
    ./Build test &&
    ./Build install
  ) || return 1;

  find "$pkgdir" -name .packlist -delete
  find "$pkgdir" -name perllocal.pod -delete
}
