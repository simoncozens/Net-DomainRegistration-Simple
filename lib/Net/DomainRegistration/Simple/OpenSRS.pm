package Net::DomainRegistration::Simple::OpenSRS;
use Carp;
use strict;
use warnings;
use base "Net::DomainRegistration::Simple";
use Net::OpenSRS;

=head1 NAME

Net::DomainRegistration::Simple::OpenSRS - Adaptor for Tucows OpenSRS

=head1 SYNOPSIS

    my $r = Net::DomainRegistration::Simple->new(
        registrar => "OpenSRS",
        environment => "live",
        username => $u,
        password => $p,
        other_auth =>
            { key => $api_key,
              master_domain => $my_domain
            }
    );

=head1 DESCRIPTION

See L<Net::DomainRegistration::Simple> for methods; see also L<Net::OpenSRS>
for operating assumptions. C<key> should be your API key, and C<master_domain>
should be your management domain.

=cut

sub _specialize { 
    my $self = shift;
    my $srs = $self->{srs} = Net::OpenSRS->new();
    if ($self->{environment}) { $srs->environment($self->{environment}) }
    $srs->set_manage_auth($self->{username}, $self->{password});
    $srs->set_key($self->{other_auth}{api_key});
    $self->_setmaster;
    if (!$self->{cookie}) {
        croak "Couldn't get OpenSRS cookie: ".$srs->last_response();
    }
}

sub _setmaster {
    my $self = shift;
    $self->{cookie} = $self->{srs}->get_cookie(
                                $self->{other_auth}{master_domain}
                      );
}

sub register {
    my ($self, %args) = @_;
    # Check $args{domain}
    # Check customer stuff
    $self->_setmaster;
    $self->{srs}->register_domain($args{domain}, $args{billing});
}

sub renew {
    my ($self, %args) = @_;
    # Check domain
    # Check year
    $self->_setmaster;
    $self->{srs}->renew_domain($args{domain}, $args{year});
}

sub revoke {
    my ($self, %args) = @_;
    # Check domain
    $self->_setmaster;
    $self->{srs}->revoke_domain($args{domain}, $args{year});
}

sub change_contact {
    my ($self, %args) = @_;
    # XXX
}

sub set_nameservers {

}

1;
