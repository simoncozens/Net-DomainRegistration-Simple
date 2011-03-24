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
        key => $api_key,
        master_domain => $my_domain
    );

=head1 DESCRIPTION

See L<Net::DomainRegistration::Simple> for methods; see also L<Net::OpenSRS>
for operating assumptions. C<key> should be your API key, and C<master_domain>
should be your management domain.

=cut

sub _specialize { 
    my $self = shift;
    my $srs = $self->{srs} = Net::OpenSRS->new();
    $srs->debug_level(2);
    if ($self->{environment}) { $srs->environment($self->{environment}) }
    $srs->set_key($self->{api_key});
    # The following line shouldn't be necessary but seems to be
    $srs->{config}->{manage_username} = $self->{username};
    $srs->set_manage_auth($self->{username}, $self->{password});
    $self->_setmaster;
    if (!$self->{cookie}) {
        croak "Couldn't get OpenSRS cookie: ".$srs->last_response();
    }
}

sub _setmaster {
    my $self = shift;
    $self->{srs}->master_domain($self->{master_domain});
    $self->{cookie} = $self->{srs}->get_cookie(
                                $self->{master_domain}
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

sub _contact_set {
    my ($self, %args) = @_;
    my $cs;
    for (qw/owner tech admin billing/){ 
        my $c = $args{$_ eq "tech"? "technical" : $_} || next;
        $cs->{$_} = {
            first_name  => $c->{firstname},
            last_name   => $c->{lastname},
            org_name    => $c->{company} || "n/a",
            address1    => $c->{address},
            city        => $c->{city},
            state       => $c->{state},
            postal_code => $c->{postcode},
            country     => $c->{country},
            phone       => $c->{phone},
            fax         => $c->{fax},
            email       => $c->{email}
        }
    }
    return $cs;
}

sub change_contact {
    my ($self, %args) = @_;
    $self->_check_domain(\%args);
    $self->{cookie} = $self->{srs}->get_cookie( $args{domain} );
    my $cs = $self->_contact_set(%args);
    my $rv = $self->{srs}->make_request({
         action     => 'modify',
         cookie     => $self->{cookie},
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
    $self->{cookie} = $self->{srs}->get_cookie( $args{domain} );
    my $tld = $args{domain}; $tld =~ s/^.*(\.\w+)$/$1/;
    # See what we have already

    my $rv;

    my $rv = $self->{srs}->make_request({
         action     => 'get',
         cookie     => $self->{cookie},
         object     => 'nameserver',
         attributes => { name => "all" }
     });
     return unless $rv->{is_success};
     my %servers = map { $_->{name} => 1 } @{$rv->{attributes}{nameserver_list}};
    for my $ns (@{$args{nameservers}}) {
        next if $servers{$ns};
        # else create
        my $ip = $self->_ipof($ns) or warn "$ns has no IP", return 0; 
        my $rv = eval { $self->{srs}->make_request({
             action     => 'registry_add_ns',
             object     => 'nameserver',
             cookie     =>  $self->{cookie},
             attributes => { fqdn => $ns, tld => $tld, all => 0 }
        }) } || {};  
        return unless $rv->{is_success};
    } 
        
    # advanced_update_nameservers
    $rv = $self->{srs}->make_request({
         action     => 'advanced_update_nameservers',
         object     => 'nameserver',
         cookie     => $self->{cookie},
         attributes => { 
            op_type => "assign",
            assign_ns => $args{nameservers}
        }
    });  
    return $rv->{is_success}
}

sub domain_info {
    my ($self, $domain) = @_;
    $self->{cookie} = $self->{srs}->get_cookie( $args{domain} );

    my $rv = $self->{srs}->make_request({
        action      => 'get',
        object      => 'domain',
        cookie      => $self->{cookie},
        attributes  => {
            type    => 'all_info'
        }
    });
    return $rv->{attributes} if $rv->is_success;
}
1;
