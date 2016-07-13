package Dist::Zilla::Plugin::Bencher::Scenario;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
use namespace::autoclean;

use Bencher::Backend;
use Dist::Zilla::File::InMemory;
use File::Slurper qw(read_binary);
use File::Spec::Functions qw(catfile);
use Module::Load;

# we need the version to insert to generated test scripts, prereqs.
$Bencher::Backend::VERSION or die "Please use Bencher with a version number";

with (
    'Dist::Zilla::Role::BeforeBuild',
    'Dist::Zilla::Role::FileGatherer',
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules'],
    },
    'Dist::Zilla::Role::PrereqSource',
);

# either provide filename or filename+filecontent
sub _get_abstract_from_scenario {
    my ($self, $filename, $filecontent) = @_;

    local @INC = @INC;
    unshift @INC, 'lib';

    unless (defined $filecontent) {
        $filecontent = do {
            open my($fh), "<", $filename or die "Can't open $filename: $!";
            local $/;
            ~~<$fh>;
        };
    }

    unless ($filecontent =~ m{^#[ \t]*ABSTRACT:[ \t]*([^\n]*)[ \t]*$}m) {
        $self->log_debug(["Skipping %s: no # ABSTRACT", $filename]);
        return undef;
    }

    my $abstract = $1;
    if ($abstract =~ /\S/) {
        $self->log_debug(["Skipping %s: Abstract already filled (%s)", $filename, $abstract]);
        return $abstract;
    }

    $self->log_debug(["Getting abstract for module %s", $filename]);
    my $pkg;
    if (!defined($filecontent)) {
        (my $mod_p = $filename) =~ s!^lib/!!;
        require $mod_p;

        # find out the package of the file
        ($pkg = $mod_p) =~ s/\.pm\z//; $pkg =~ s!/!::!g;
    } else {
        eval $filecontent;
        die if $@;
        if ($filecontent =~ /\bpackage\s+(\w+(?:::\w+)*)/s) {
            $pkg = $1;
        } else {
            die "Can't extract package name from file content";
        }
    }

    no strict 'refs';
    my $scenario = ${"$pkg\::scenario"};

    $scenario->{summary};
}

# dzil also wants to get abstract for main module to put in dist's
# META.{yml,json}
sub before_build {
    my $self  = shift;
    my $name  = $self->zilla->name;
    my $class = $name; $class =~ s{ [\-] }{::}gmx;
    my $filename = $self->zilla->_main_module_override ||
        catfile( 'lib', split m{ [\-] }mx, "${name}.pm" );

    $filename or die 'No main module specified';
    -f $filename or die "Path ${filename} does not exist or not a file";
    open my $fh, '<', $filename or die "File ${filename} cannot open: $!";

    my $abstract = $self->_get_abstract_from_scenario($filename);
    return unless $abstract;

    $self->zilla->abstract($abstract);
    return;
}

sub gather_files {
    require Dist::Zilla::File::InMemory;

    my ($self) = @_;

    # add t/bench-*.t
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!\Alib/Bencher/Scenario/(.+)\.pm\z!;
        my $bs_name = $1; $bs_name =~ s!/!::!g;
        my $script_name = $bs_name; $script_name =~ s!::!-!g;
        my $filename = "t/bench-$script_name.t";
        my $filecontent = q[
#!perl

# This file was automatically generated by Dist::Zilla::Plugin::Bencher::Scenario.

use Test::More;

eval "use Bencher::Backend ].$Bencher::VERSION.q[";
plan skip_all => "Bencher::Backend ].$Bencher::VERSION.q[ required to run benchmark" if $@;
plan skip_all => "EXTENDED_TESTING not turned on" unless $ENV{EXTENDED_TESTING};

diag explain Bencher::Backend::bencher(action=>'bench', return_meta=>1, scenario_module=>'].$bs_name.q[');
ok 1;

done_testing();
];
        $self->log(["Adding %s ...", $filename]);
        $self->add_file(
            Dist::Zilla::File::InMemory->new({
                name => $filename,
                content => $filecontent,
            })
          );
    }
    $self->zilla->register_prereqs(
        {phase=>'test', type=>'requires'}, 'Bencher::Backend', $Bencher::Backend::VERSION);
}

sub munge_files {
    no strict 'refs';
    my $self = shift;

    local @INC = ("lib", @INC);

    # gather dist modules
    my %distmodules;
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!\Alib/(.+)\.pm\z!;
        my $mod = $1; $mod =~ s!/!::!g;
        $distmodules{$mod}++;
    }

    my %seen_mods;
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!\Alib/(Bencher/Scenario/.+)\.pm\z!;

        # add prereq to participant modules
        my $pkg = $1; $pkg =~ s!/!::!g;
        load $pkg;
        my $scenario = Bencher::Backend::parse_scenario(scenario=>${"$pkg\::scenario"});
        my @modules = Bencher::Backend::_get_participant_modules($scenario);
        for my $mod (@modules) {
            next if $distmodules{$mod};
            next if $seen_mods{$mod}++;
            my $ver = $scenario->{modules}{$mod}{version} // 0;
            $self->log_debug(
                ["Adding prereq to benchmarked module %s (version %s)",
                 $mod, $ver]);
            $self->zilla->register_prereqs(
                {phase=>'runtime', type=>'requires'}, $mod, $ver);
        }

        # fill-in ABSTRACT from scenario's summary
        my $content = $file->content;
        {
            my $abstract = $self->_get_abstract_from_scenario(
                $file->name, $content);
            last unless $abstract;
            $content =~ s{^#\s*ABSTRACT:.*}{# ABSTRACT: $abstract}m
                or die "Can't insert abstract for " . $file->name;
            $self->log(["inserting abstract for %s (%s)",
                        $file->name, $abstract]);

            $file->content($content);
        }
    } # foreach file
    return;
}

# we abuse this PrereqSource phase (comes after FileMunger phase, which is after
# Pod::Weaver::Plugin::Bencher::Scenario) to add files generated by it

sub register_prereqs {
    my $self = shift;
    my $tempdir = $self->zilla->{_pwp_bs_tempdir};
    return unless $tempdir;

    opendir my($dh), $tempdir or die;
    for my $fname (readdir $dh) {
        next unless $fname =~ /\.png\z/;
        my $file = Dist::Zilla::File::InMemory->new(
            name => "share/images/$fname",
            encoded_content => read_binary("$tempdir/$fname"),
        );
        $self->log(["Adding chart image file %s into share/images/", $fname]);
        $self->add_file($file);
    }
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Plugin to use when building Bencher::Scenario::* distribution

=for Pod::Coverage .+

=head1 SYNOPSIS

In F<dist.ini>:

 [Bencher::Scenario]


=head1 DESCRIPTION

This plugin is to be used when building C<Bencher::Scenario::*> distribution.
It currently dos the following:

=over

=item * Add the benchmarked modules as RuntimeRequires prereqs

=item * Add Bencher::Backend (the currently installed version during building) to TestRequires prereq and add test files C<t/bench.t-*>

=item * Fill-in ABSTRACT from scenario's summary

=item * Add chart images generated by L<Pod::Weaver::Plugin::Bencher::Scenario> into the build

=back


=head1 SEE ALSO

L<Bencher>

L<Pod::Weaver::Plugin::Bencher::Scenario>
