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

sub is_available {
    my ($self, $domain) = @_;
    $self->_setmaster;
    $self->{srs}->is_available($domain);
}

sub register {
    my ($self, %args) = @_;
    $self->_check_register(\%args);
    # XXX Massage contact stuff
    $self->_setmaster;
    $self->{srs}->register_domain($args{domain}, $args{billing});
    $self->set_nameservers(domain => $args{domain}, nameservers => $args{nameservers});
}

sub renew {
    my ($self, %args) = @_;
    $self->_check_renew(\%args);
    $self->_setmaster;
    $self->{srs}->renew_domain($args{domain}, $args{years});
}

sub revoke {
    my ($self, %args) = @_;
    # Check domain
    $self->_check_domain(\%args);
    $self->_setmaster;
    $self->{srs}->revoke_domain($args{domain});
}

sub change_contact {
    my ($self, %args) = @_;
    $self->_check_domain(\%args);
    $self->{cookie} = $self->{srs}->get_cookie( $args{domain} );
    # Massage contact set into appropriate format
    my $cs = $args{contacts};

    my $rv = $self->{srs}->make_request({
         action     => 'modify',
         object     => 'domain',
         attributes => {
             affect_domains => 0,
             data => "contact_info",
             contact_set => $cs,

         }
     });
     return $rv and $rv->{is_success};
}

sub set_nameservers {
    my ($self, %args) = @_;
    $self->_check_set_nameservers(\%args); 
    $self->{cookie} = $self->{srs}->get_cookie( $args{domain} );
    # See what we have already
    my $rv = $self->{srs}->make_request({
         action     => 'get',
         object     => 'nameserver',
         attributes => { name => "all" }
     });
     return unless $rv->{is_success};
     my %servers = map { $_->{name} => 1 } @{$rv->{attributes}{nameserver_list}};
    for my $ns (@{$args{nameservers}}) {
        next if $servers{$ns};
        # else create
        my $rv = $self->{srs}->make_request({
             action     => 'create',
             object     => 'nameserver',
             attributes => { name => $ns, $self->_ipof($ns) }
        });  
        return unless $rv->{is_success};
    } 
        
    # advanced_update_nameservers
    $rv = $self->{srs}->make_request({
         action     => 'advanced_update_nameservers',
         object     => 'nameserver',
         attributes => { 
            op_type => "assign",
            assign_ns => @{$args{nameservers}}
        }
    });  
    return $rv->{is_success}
}

1;
