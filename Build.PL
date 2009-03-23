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
    },
    requires => {
        'Readonly'              => 0, # <-- The only module not in
        'CPANPLUS'              => 0, #     core for perl 5.10
        'Digest::MD5'           => 0,
        'File::Path'            => 0, # I'm not sure which versions
        'File::Copy'            => 0, # are necessary?
        'File::stat'            => 0,
        'IPC::Cmd'              => 0,
        'Module::CoreList'      => 0,
        'File::Spec::Functions' => 0,
    },
    add_to_cleanup      => [ 'CPANPLUS-Dist-Arch-*' ],
    create_makefile_pl  => 'traditional',
);

$builder->create_build_script();
