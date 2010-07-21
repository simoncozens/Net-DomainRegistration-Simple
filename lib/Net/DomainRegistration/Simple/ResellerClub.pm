package Net::DomainRegistration::Simple::ResellerClub;
our $testing = 0;
use Data::Dumper;
use Carp;
use LWP::Simple;
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
    my $u = URI->new("https://".
    ((defined $self->{environment} and $self->{environment} eq "live") ? 
                        "httpapi.com" : 
                        "test.httpapi.com")."/api/$path.json");
    $u->query_form("auth-userid" => $self->{username}, 
                   "auth-password" => $self->{password},
                   %args);
    if ($testing) { warn " > $u \n"; }
    my $res = LWP::Simple::get($u);
    return unless $res;
    $res = eval  { decode_json($res) } || $res;
    if ($testing) { warn " < ".Dumper($res); }
    return $res;
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

sub is_available { 
    my ($self, $domain) = @_;
    $domain =~ /([^\.]+)\.(.*)/;
    my $res = $self->_req("domains/available", "domain-name" => $1, tlds => $2,
    "suggest-alternative" => "false");
    $res->{$domain}{status} eq "available";
}

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

sub revoke {
    my ($self, %args) = @_;
    $self->_check_domain(\%args);
    my $id = $self->_req("domains/orderid", "domain-name" => $args{domain}) or return;
    $self->_req("domains/cancel", "order-id" => $id);
}

sub change_contact { return 1 }

sub set_nameservers { 
    my ($self, %args) = @_;
    $self->_check_set_nameservers(\%args);
    # Actually, it doesn't want the dots on them.
    s/\.$// for @{$args{nameservers}};
    my $id = $self->_req("domains/orderid", "domain-name" => $args{domain}) or return;
    $self->_req("domains/modify-ns", "order-id" => $id, ns => $args{nameservers});
}
1;
