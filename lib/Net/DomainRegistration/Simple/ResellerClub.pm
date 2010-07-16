package Net::DomainRegistration::Simple::ResellerClub;
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
    my $res = LWP::Simple::get($u);
    return unless $res;
    $res = eval  { decode_json($res) };
    return $res;
}

sub register { return 1 }
sub is_available { 
    my ($self, $domain) = @_;
    $domain =~ /([^\.]+)\.(.*)/;
    my $res = $self->_req("domains/available", "domain-name" => $1, tlds => $2,
    "suggest-alternative" => "false");
    die Dumper $res->{$domain};
}

sub renew { return 1 }
sub revoke { return 1 }
sub change_contact { return 1 }
sub set_nameservers { return 1 }

1;
