package Dist::Zilla::Plugin::Bencher::Scenario;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
use namespace::autoclean;

use Bencher;
use Module::Load;

with (
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules'],
    },
);

sub munge_files {
    no strict 'refs';
    my $self = shift;

    local @INC = ("lib", @INC);

    my %seen_mods;
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!\Alib/(Bencher/Scenario/.+)\.pm\z!;
        my $pkg = $1; $pkg =~ s!/!::!g;
        load $pkg;
        my $scenario = Bencher::parse_scenario(scenario=>${"$pkg\::scenario"});
        my @modules = Bencher::_get_participant_modules($scenario);
        for my $mod (@modules) {
            next if $seen_mods{$mod}++;
            $self->log_debug(["Adding prereq to benchmarked module %s", $mod]);
            $self->zilla->register_prereqs(
                {phase=>'runtime', type=>'recommends'}, $mod, 0);
        }
    }
    return;
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Do various stuffs for Bencher-Scenario-* distribution

=for Pod::Coverage .+

=head1 SYNOPSIS

In F<dist.ini>:

 [Bencher::Scenario]


=head1 DESCRIPTION

This plugin is meant to be use when building C<Bencher-Scenario-*> distribution
(e.g.: L<Bencher::Scenario::SetOperationModules>,
L<Bencher::Scenario::Serializers>). Currently what it does are the following:

=over

=item * Add the benchmarked modules as RuntimeRecommends prereqs

=back


=head1 SEE ALSO

L<Bencher>

L<Pod::Weaver::Plugin::Bencher::Scenario>
