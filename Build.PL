use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'CPANPLUS::Dist::Arch',
    license             => 'perl',
    dist_author         => 'Justin Davis <jrcd83@gmail.com>',
    dist_version_from   => 'lib/CPANPLUS/Dist/Arch.pm',
    build_requires => {
        'Test::More' => 0,
        'Net::Ping'  => 0,
    },
    requires => {
        # 'perl'                  => '5.8.0', # thx to CPAN Testers
        # above might have changed without Readonly

        'CPANPLUS'              => 0,
        'Digest::MD5'           => 0,
        'File::Path'            => 0, # I'm not sure which versions
        'File::Copy'            => 0, # are necessary?
        'File::stat'            => 0,
        'IPC::Cmd'              => 0,
        'DynaLoader'            => 0,
        'Pod::Select'           => 0,
        'Module::CoreList'      => 0,
        'File::Spec::Functions' => 0,
        'Carp'                  => 0,

        'Getopt::Long'          => 0, # for the setupdistarch script
        'Pod::Usage'            => 0,
    },
    meta_add => { resources =>
                  { repository =>
                    'http://github.com/juster/perl-cpanplus-dist-arch' }},
    script_files => [ qw{ script/cpan2aur script/setupdistarch } ],
    add_to_cleanup      => [ 'CPANPLUS-Dist-Arch-*' ],
    create_makefile_pl  => 'traditional',
);

$builder->create_build_script();
