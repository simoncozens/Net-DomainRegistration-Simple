package Net::DomainRegistration::Simple::ResellerClub;
our $testing = 0;
use Data::Dumper;
use Carp;
use LWP::UserAgent;
use JSON::XS;
use strict;
use warnings;
use base "Net::DomainRegistration::Simple";

=head1 NAME

Net::DomainRegistration::Simple::ResellerClub - Adaptor for ResellerClub

=head1 SYNOPSIS

    my $r = Net::DomainRegistration::Simple->new(
        registrar => "ResellerClub",
        environment => "live",
        username => $u,
        password => $p,

    );
    $r->register_domain( ... ); 

=head1 DESCRIPTION

See L<Net::DomainRegistration::Simple> for methods. This uses
ResellerClub's HTTP API which is currently in beta.

Note also that your username should be your Reseller ID, not the email
address you use to log into the web site.

=cut

sub _specialize {}
sub _req {
    my ($self, $path, %args) = @_;

    my $url = "https://".
    ((defined $self->{environment} and $self->{environment} eq "live") ? 
                        "httpapi.com" : 
                        "test.httpapi.com")."/api/$path.json";


    my $ua = LWP::UserAgent->new();
    $ua->timeout(20);

    $args{'auth-userid'} = $self->{username};
    $args{'auth-password'} = $self->{password};

    my $post_methods = "(register|transfer|renew|modify-ns|add-cns|modify-cns-name|modify-cns-ip|modify-contact|modify-privacy-protection|modify-auth-code|enable-theft-protection|disable-theft-protection|lock-orders|unlock-orders|modify-whois-pref|release|cancel-transfer|delete|restore|trade|add|set-details|add-sponsor|signup|change-password)";

    my $method = "get";
    if ( $path =~ /$post_methods/ ) {
        $method = "post";
    }
    else {
        $url .= '?';
        foreach (keys %args) {
            $url .= $_ . '=' . $args{$_} . '&';
        }
        chop $url; # remove trailing &
    }

    $method = "post" if $path =~ /$post_methods/;

    if ($testing) { warn " > $method : " . $url; }
    my $res = undef;
    if ( $method eq 'get' ) {
        $res = $ua->$method($url); 
    }
    else {
        $res = $ua->$method($url, \%args);
    }

    if ($testing) { warn " < ".Dumper($res); }
    if ( $res->{'_rc'} > 200 ) { die "Error: ".Dumper($res); }

    return unless $res;
    my $result = eval  { decode_json($res->content) } || $res->content;
    if ($testing) { warn " < ".Dumper($result); }
    return $result;
}

sub _contact_set {
    my ($self, %args) = @_;
    my %contacts;
    my $lastentry;
    # Propagate entries in this order -> 
    for (qw/admin technical billing registrant customer /) {
        my $entry = $args{$_} || $lastentry or next;
        $lastentry = $entry;
        my ($cc, $phone) = 
            ($entry->{phone} =~ /^(?:\+(\d{2})\W(.*))|^(?:()(.*))$/);
        $contacts{$_} = {
            name => $entry->{firstname}." ".$entry->{lastname},
            company => $entry->{company} || "n/a",
            email => $entry->{email},
            "address-line-1" => $entry->{address},
            city => $entry->{city},
            country => $entry->{country},
            zipcode => $entry->{postcode},
            "phone-cc" => $cc,
            phone => $phone
        };
    }
    return %contacts;
}

=head2 register

=cut

sub register { 
    my ($self, %args) = @_;
    $self->_check_register(\%args);
    my %contacts = $self->_contact_set(%args) or return; 

    return if !$self->is_available($args{domain});

    # Do we have a customer record for this customer?
    my $customer = $contacts{customer} || $contacts{registrant} 
                    || $contacts{admin} || $contacts{billing};
    my $c_rec = $self->_req("customers/details", username => $customer->{email});
    unless ($c_rec->{username}) { # Nope, make one
        $c_rec->{customerid} = $self->_req("customers/signup",
            username => delete $customer->{email},
            passwd => genpass(),
            %$customer
        );
        return unless $c_rec->{customerid};
    }
    
    # Do we have a contact for each of the things we're passing in?
    for (qw/registrant admin billing technical/) {
        my $search = $self->_req("contacts/search", 
            "customer-id" => $c_rec->{customerid},
            "no-of-records" => 10, "page-no" => 1, 
            email => $contacts{$_}{email}); 
        
        my @results = @{$search->{result}};
        if ($results[0]) {
            $contacts{$_}{contactid} = $results[0]{"contact.contactid"};
        } else {
            $contacts{$_}{contactid} = 
                $self->_req("contacts/add",
                    "customer-id" => $c_rec->{customerid},
                    type => "Contact",
                    %{$contacts{$_}}
                );
        }
    }           
    return $self->_req("domains/register", 
        "domain-name" => $args{domain},
        years => $args{years} || 1,
        ns => $args{nameservers},
        "customer-id" => $c_rec->{customerid},
        "invoice-option" => "NoInvoice",
        "protect-privacy" => 1,
        "tech-contact-id" => $contacts{technical}{contactid},
        "reg-contact-id" => $contacts{registrant}{contactid},
        map {; "$_-contact-id" => $contacts{$_}{contactid} } 
           qw/admin billing/);
}

=head2 transfer

=cut

sub transfer { 
    my ($self, %args) = @_;
    $self->_check_transfer(\%args);
    my %contacts = $self->_contact_set(%args) or return; 

    # The domain cannot be transferred if it is "available" as that
    # would mean it doesn't exist.
    return if $self->is_available($args{domain});

    # Do we have a customer record for this customer?
    my $customer = $contacts{customer} || $contacts{registrant} 
                    || $contacts{admin} || $contacts{billing};
    my $c_rec = $self->_req("customers/details", username => $customer->{email});
    unless ($c_rec->{username}) { # Nope, make one
        $c_rec->{customerid} = $self->_req("customers/signup",
            username => delete $customer->{email},
            passwd => genpass(),
            %$customer
        );
        return unless $c_rec->{customerid};
    }
    
    # Do we have a contact for each of the things we're passing in?
    for (qw/registrant admin billing technical/) {
        my $search = $self->_req("contacts/search", 
            "customer-id" => $c_rec->{customerid},
            "no-of-records" => 10, "page-no" => 1, 
            email => $contacts{$_}{email}); 
        
        my @results = @{$search->{result}};
        if ($results[0]) {
            $contacts{$_}{contactid} = $results[0]{"contact.contactid"};
        } else {
            $contacts{$_}{contactid} = 
                $self->_req("contacts/add",
                    "customer-id" => $c_rec->{customerid},
                    type => "Contact",
                    %{$contacts{$_}}
                );
        }
    }           
    return $self->_req("domains/transfer", 
        "domain-name" => $args{domain},
        "auth-code" => $args{authcode},
        ns => $args{nameservers},
        "customer-id" => $c_rec->{customerid},
        "invoice-option" => "NoInvoice",
        "protect-privacy" => 1,
        "tech-contact-id" => $contacts{technical}{contactid},
        "reg-contact-id" => $contacts{registrant}{contactid},
        map {; "$_-contact-id" => $contacts{$_}{contactid} } 
           qw/admin billing/);
}

=head2 is_available 

    if ( $rc->is_available('example.com') ) {
        ...
    }

Checks to see if the domain is available

=cut

sub is_available { 
    my ($self, $domain) = @_;
    $domain =~ /([^\.]+)\.(.*)/;
    my $res = $self->_req("domains/available", "domain-name" => $1, tlds => $2,
    "suggest-alternative" => "false");
    $res->{$domain}{status} eq "available";
}

=head2 renew

    $rc->renew(domain => 'example.com', years => 2);

Renews the domain registration

=cut

sub renew {
    my ($self, %args) = @_;
    $self->_check_renew(\%args);
    my $id = $self->_req("domains/orderid", "domain-name" => $args{domain}) or return;
    my $details = $self->_req("domains/details", "order-id" => $id,
options => "OrderDetails") or return; 

    $self->_req("domains/renew", "order-id" => $id, years => $args{years},
                    "exp-date" => $details->{endtime}, 
                    "invoice-option" => $args{invoice} || "NoInvoice"
    );
}

=head2 revoke

=cut

sub revoke {
    my ($self, %args) = @_;
    $self->_check_domain(\%args);
    my $id = $self->_req("domains/orderid", "domain-name" => $args{domain}) or return;
    $self->_req("domains/cancel", "order-id" => $id);
}

=head2 change_contact

Does nothing!

=cut

sub change_contact { return 1 }

=head2 set_nameservers

=cut

sub set_nameservers { 
    my ($self, %args) = @_;
    $self->_check_set_nameservers(\%args);
    # Actually, it doesn't want the dots on them.
    s/\.$// for @{$args{nameservers}};
    my $id = $self->_req("domains/orderid", "domain-name" => $args{domain}) or return;
    $self->_req("domains/modify-ns", "order-id" => $id, ns => $args{nameservers});
}

=head2 get_auth_code

    $rc->get_auth_code('example.com');

Get an auth code to enable the domain to be transferred to another registrar

=cut

sub get_auth_code {
    my ($self, $domain) = @_;
    $self->_check_domain({ domain => $domain});

    # There isn't a method in the API to retrieve the auth code
    # so we use the modify-auth-code method to set one according
    # to our needs

    my $authcode = join '', (0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64];

    my $orderid = $self->_get_order_id($domain);

    return unless $self->_req("domains/modify-auth-code", "order-id" => $orderid, "auth-code" => $authcode);
    return $authcode;
}

=head2 unlock_domain

=cut

sub unlock_domain {
    my ($self, $domain) = @_;

    # die "Domain not valid"  unless $self->_check_domain( {domain => $domain} );

    my $orderid = $self->_get_order_id($domain);

    return unless $self->_req("domains/disable-theft-protection", "order-id" => $orderid);
    return 1;
}

=head2 lock_domain

=cut

sub lock_domain {
    my ($self, $domain) = @_;

    my $orderid = $self->_get_order_id($domain);

    return unless $self->_req("domains/enable-theft-protection", "order-id" => $orderid);
    return 1;
}

=head2 domain_info

=cut

sub domain_info {
    my ($self, $domain) = @_;

    my $orderid = $self->_get_order_id($domain);

    return $self->_req("domains/details", "order-id" => $orderid, options => "All");
}

sub _get_order_id {
    my ($self, $domain) = @_;
    return unless $domain;

    return $self->_req("domains/orderid", "domain-name" => $domain);
}

1;
