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
    $res = eval  { decode_json($res) };
    if ($testing) { warn " < ".Dumper($res); }
    return $res;
}

sub register { 
    # We're going to use the same strategy as Nominet here, creating
    # domain-specific contact records, although there's a separate step
    # because we have to create a customer as well
    my ($self, %args) = @_;
    $self->_check_register(\%args);
    return if !$self->is_available($args{domain});

    my $id = sprintf("%x", time);
    my %stuff = $self->_contact_set(%args) or return;
    $self->{epp}->create_contact({ id => $id, %stuff, authInfo => "1234" }) or return

    return 1 

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
sub revoke { return 1 }
sub change_contact { return 1 }
sub set_nameservers { return 1 }

1;
