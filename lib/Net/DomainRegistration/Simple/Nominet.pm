package Net::DomainRegistration::Simple::Nominet;
use Carp;
use strict;
use warnings;
use base "Net::DomainRegistration::Simple";
use Net::EPP::Simple;

=head1 NAME

Net::DomainRegistration::Simple::Nominet - Adaptor for Nominet

=head1 SYNOPSIS

    my $r = Net::DomainRegistration::Simple->new(
        registrar => "Nominet",
        environment => "live",
        username => $u,
        password => $p,
        other_auth => { registrar_contact_id => $cid }
    );

=head1 DESCRIPTION

See L<Net::DomainRegistration::Simple> for methods; see also
L<Net::EPP::Simple>.

Easy to subclass for other EPP-based services by inheriting and
overriding _epp_host.

=cut

sub _epp_host {
    my $self = shift;
    (defined $self->{environment} and $self->{environment} eq "live") 
        ? "epp.nominet.org.uk"
        : "testbed-epp.nominet.org.uk";
}

sub _specialize { 
    my $self = shift;
    $self->{epp} = Net::EPP::Simple::Nominet->new(
        host => $self->_epp_host,
        user => $self->{username},
        pass => $self->{password}
    );
}

sub register {
    my ($self, %args) = @_;
    $self->_check_register(\%args);
    # XXX Create contact records
    my $t;
    my $a;
    my $b;
    $self->{epp}->create_domain({
        name => $args{domain},
        registrant => $args{registrant} || $self->{other_auth}{registrar_contact_id},
        contacts => { tech => $t, admin => $a, billing => $b },
        status => "clientTransferProhibited", 
    });
}

sub renew {
    my ($self, %args) = @_;
    $self->_check_renew(\%args);
    # Find current expiry date
    # Check it's within 6months
    
    #my $response = $self->request($frame);
    #$Code = $self->_get_response_code($response);
    #$Message = $self->_get_message($response);


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

    # Get the current ones.
    my $info = $self->{epp}->domain_info($args{domain}) or return;
    my %current = map {$_=>1} @{$info->{ns}};
    my %toadd;

    for my $ns (@{$args{nameservers}}) {
        next if delete $current{$ns};
        $toadd{$ns}++;
        if ($self->{epp}->check_host($ns) == 0) { next; }
        # otherwise create the entry
        # XXX Need to create a "superordinate host entry"
        $self->{epp}->create_host({
            'name' => $ns,
            addrs => [{ version => "v4", addr => $self->_ip_f($ns) }]
        }) or return;
    } 
    
    # What's left in $current needs to be deleted, and what's left in
    # $toadd needs to be added
 
    my $frame = Net::EPP::Frame::Command::Update::Domain->new();
    $frame->setDomain($args{domain});

    my $e = $frame->createElement("domain:ns");
    for (keys %toadd) {
        my $a = $frame->createElement("domain:hostObj");
        s/\.$//;
        $a->appendText($_);
        $e->addChild($a);
    }
    #$frame->add->addChild($e);
    #$frame->add->parentNode->removeChild($frame->add);
    $frame->chg->parentNode->removeChild($frame->chg);
    #$frame->rem->parentNode->removeChild($frame->rem);

    $e = $frame->createElement("domain:ns");
    for (keys %current) {
        my $a = $frame->createElement("domain:hostObj");
        s/\.$//;
        $a->appendText($_);
        $e->addChild($a);
        last;
    }
    #$frame->rem->addChild($e);
    $self->{epp}->request($frame);
}

# All this gubbins just to add a couple of "options" to the login frame
package Net::EPP::Simple::Nominet;
use base "Net::EPP::Simple";

use constant EPP_XMLNS  => 'urn:ietf:params:xml:ns:epp-1.0';
our $Error  = '';
our $Code   = 1000;
our $Message    = '';
no warnings; # The code isn't warnings clean. Boo.

sub new {
    my ($package, %params) = @_;
    $params{dom}        = 1;
    $params{port}       = (int($params{port}) > 0 ? $params{port} : 700);
    $params{ssl}        = ($params{no_ssl} ? undef : 1);

    #my $self = $package->SUPER::new(%params);
    my $self = $package->Net::EPP::Client::new(%params);

    $self->{debug}      = int($params{debug});
    $self->{timeout}    = (int($params{timeout}) > 0 ? $params{timeout} : 5);

    bless($self, $package);

    $self->debug(sprintf('Attempting to connect to %s:%d', $self->{host}, $self->{port}));
    $self->{greeting} = $self->connect;

    map { $self->debug('S: '.$_) } split(/\n/, $self->{greeting}->toString(1));

    $self->debug('Connected OK, preparing login frame');

    my $login = Net::EPP::Frame::Command::Login->new;

    $login->clID->appendText($params{user});
    $login->pw->appendText($params{pass});

    # Seriously, this is all we've added to this method.
    my $option;
    my $v = $login->can("version") ? $login->version : 
        do { 
            $option = $login->createElement("version");
            $login->options->appendChild($option);
            $option;
        };
    $v->appendText("1.0");

    my $l = $login->can("lang") ? $login->lang : do {
        $option = $login->createElement("lang");
        $login->options->appendChild($option);
        $option;
    };
    $l->appendText("en");

    my $objects = $self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'objURI');
    while (my $object = $objects->shift) {
        next unless $object->firstChild->data =~ /^urn:.*1\.0$/;
        my $el = $login->createElement('objURI');
        $el->appendText($object->firstChild->data);
        $login->svcs->appendChild($el);
    }
    #$objects = $self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'extURI');
    #while (my $object = $objects->shift) {
    #    my $el = $login->createElement('objURI');
    #    $el->appendText($object->firstChild->data);
    #    $login->svcs->appendChild($el);
    #}

    $self->debug(sprintf('Attempting to login as client ID %s', $self->{user}));
    my $response = $self->request($login);

    $Code = $self->_get_response_code($response);
    $Message = $self->_get_message($response);

    $self->debug(sprintf('%04d: %s', $Code, $Message));

    if ($Code > 1999) {
        $Error = "Error logging in (response code $Code)";
        return undef;
    }

    return $self;
}


1;
