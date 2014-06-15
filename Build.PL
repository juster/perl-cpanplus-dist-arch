use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'CPANPLUS::Dist::Arch',
    license             => 'perl',
    dist_author         => 'Justin Davis < juster at cpan dot org >',
    dist_version_from   => 'lib/CPANPLUS/Dist/Arch.pm',
    test_requires => {
        'Test::More' => 0,
    },
    requires => {
        # 'perl'                  => '5.8.0', # thx to CPAN Testers
        # above might have changed without Readonly

        'CPANPLUS'              => 0,
        'Digest::MD5'           => 0,
        'File::Path'            => '2.06_05', # for make_path and remove_tree
        'File::Copy'            => 0,
        'File::stat'            => 0,
        'IPC::Cmd'              => 0,
        'DynaLoader'            => 0,
        'Pod::Select'           => 0,
        'Module::CoreList'      => 0,
        'File::Spec::Functions' => 0,
        'Carp'                  => 0,

        # cpan2aur
        'Term::ANSIColor'       => 0,
        'Archive::Tar'          => 0,
        'Text::Wrap'            => 0,
        'IO::Zlib'              => 0,
        'version'               => 0,
        'POSIX'                 => 0,
        'Cwd'                   => 0,

        # cpan2aur and setupdistarch
        'Getopt::Long'          => 0,
        'Pod::Usage'            => 0,
    },
    meta_add => { resources =>
                  { repository =>
                    'http://github.com/juster/perl-cpanplus-dist-arch' }},
    script_files        => [ qw{ script/cpan2aur script/setupdistarch } ],
    add_to_cleanup      => [ 'CPANPLUS-Dist-Arch-*' ],
    create_makefile_pl  => 'traditional',
);

$builder->create_build_script();
