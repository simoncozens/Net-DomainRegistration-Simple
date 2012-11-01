package Net::DomainRegistration::Simple::Dummy;
use Carp;
use strict;
use warnings;
use base "Net::DomainRegistration::Simple";

=head1 NAME

Net::DomainRegistration::Simple::Dummy - Adaptor that doesn't do anything

=head1 SYNOPSIS

    my $r = Net::DomainRegistration::Simple->new(
        registrar => "Dummy",
        environment => "live",
        username => $u,
        password => $p,
    );
    $r->register_domain( ... ); # NOTHING HAPPENS


=head1 DESCRIPTION

See L<Net::DomainRegistration::Simple> for methods. This module conforms
to the interface but the methods don't do anything. Useful for testing
and as a base module.

=head2 is_available

=head2 register

=head2 transfer

=head2 renew

=head2 revoke

=head2 change_contact

=head2 set_nameservers

=cut

sub _specialize { }

sub register { return 1 }
sub is_available { return 1 }
sub renew { return 1 }
sub transfer { return 1 }
sub revoke { return 1 }
sub change_contact { return 1 }
sub set_nameservers { return 1 }

1;
