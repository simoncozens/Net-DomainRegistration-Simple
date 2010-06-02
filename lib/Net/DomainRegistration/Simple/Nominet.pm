package Net::DomainRegistration::Simple::Nominet;
use Carp;
use strict;
use warnings;
use base "Net::DomainRegistration::Simple";
use Net::EPP::Simple;
use Time::Piece;
use Time::Seconds;

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
        pass => $self->{password},
        debug => 1,
    );
}

sub is_available {
    my ($self, $domain) = @_;
    $self->{epp}->check_domain($domain);
}

sub _contact_set {
    my ($self, %args) = @_;
    my $contact = $args{registrant} || $args{technical} || $args{admin} || $args{billing};
    return unless $contact;
    return (
        postalInfo => {
            int => {
                name => $contact->{firstname}." ".$contact->{lastname},
                org => $contact->{company},
                addr => {
                    street => [ $contact->{address} ],
                    city => $contact->{city},
                    sp => $contact->{state},
                    pc => $contact->{postcode},
                    cc => $contact->{country},
                }
            }
        },
        voice => $contact->{phone},
        fax   => $contact->{fax},
        email => $contact->{email}
    )
}

sub register {
    my ($self, %args) = @_;
    $self->_check_register(\%args);
    return if !$self->is_available($args{domain});

    my $id = sprintf("%x", time); # XXX will break on May 10th 584554533311AD
    my %stuff = $self->_contact_set(%args) or return;
    $self->{epp}->create_contact({ id => $id, %stuff, authInfo => "1234" }) or return;

    for my $ns (@{$args{nameservers}}) {
        $self->_ensure_host($ns) or return;
    }

    $self->{epp}->create_domain({
        name => $args{domain},
        registrant => $id,
        status => "clientTransferProhibited", 
        period => 2, # No choice about this for Nominet
        $args{nameservers} ? (ns => [ @{$args{nameservers}} ]) : (), 
        authInfo => "1234"
    }) or return;
}

sub renew {
    my ($self, %args) = @_;
    $self->_check_renew(\%args);

    my $info = $self->{epp}->domain_info($args{domain}) or return;
    my $d = $info->{exDate];
    $d =~ s/T.*//; # Avoid "garbage at end of string";
    my $t = Time::Piece->strptime($d, "%Y-%m-%d");
    return if $t - 180*ONE_DAY > Time::Piece->new;
    #XXX
    
    my $frame = Net::EPP::Frame::Command::Renew::Domain->new;
    $frame->setDomain($args{domain});
    $frame->setCurExpDate($d);
    $frame->setPeriod(2);
    $self->{epp}->request($frame);
}

sub revoke {
    my ($self, %args) = @_;
    # Check domain
    $self->_check_domain(\%args);
    # XXX
}

sub _get_registrant {
    my ($self, $domain) = @_;
    my $info = $self->{epp}->domain_info($domain);
    return $info->{registrant} if $info;
}

sub change_contact {
    my ($self, %args) = @_;
    $self->_check_domain(\%args);
    my %stuff = $self->_contact_set(%args) or return;
    my $contact = \%stuff;

    my $frame = Net::EPP::Frame::Command::Update::Contact->new();
    my $id = $self->_get_registrant($args{domain}) or return;
    $frame->setContact($id);
    if (ref($contact->{postalInfo}) eq 'HASH') {
        foreach my $type (keys(%{$contact->{postalInfo}})) {
            $frame->Net::EPP::Frame::Command::Create::Contact::addPostalInfo(
                $type,
                $contact->{postalInfo}->{$type}->{name},
                $contact->{postalInfo}->{$type}->{org},
                $contact->{postalInfo}->{$type}->{addr}
            );
        }
    }

    $frame->Net::EPP::Frame::Command::Create::Contact::setVoice($contact->{voice}) if ($contact->{voice} ne '');
    $frame->Net::EPP::Frame::Command::Create::Contact::setFax($contact->{fax}) if ($contact->{fax} ne '');
    $frame->Net::EPP::Frame::Command::Create::Contact::setEmail($contact->{email});
    $frame->Net::EPP::Frame::Command::Create::Contact::setAuthInfo('1234');

    $frame->rem->parentNode->removeChild($frame->rem);
    $frame->add->parentNode->removeChild($frame->add);
    
    $self->{epp}->request($frame);
}

sub _ensure_host {
    my ($self, $host) = @_;
    if ($self->{epp}->check_host($host) == 0) { return 1; }
    $self->{epp}->create_host({
        'name' => $host,
        addrs => [{ version => "v4", addr => $self->_ip_of($host) }]
    });
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
        $self->_ensure_host($ns) or return;
        # XXX Need to create a "superordinate host entry"
    } 
    
    # What's left in $current needs to be deleted, and what's left in
    # $toadd needs to be added
 
    my $frame = Net::EPP::Frame::Command::Update::Domain->new();
    my $name = $frame->setDomain($args{domain});

    my $e = $frame->createElement("domain:ns");
    for (keys %toadd) {
        my $a = $frame->createElement("domain:hostObj");
        s/\.$//;
        $a->appendText($_);
        $e->addChild($a);
    }
    $frame->add->addChild($e);
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
    $frame->rem->addChild($e);
    $self->{epp}->request($frame);
}

sub poll {
    my ($self) = @_;
    my $frame = Net::EPP::Frame::Command::Poll::Req->new();
    my $resp = $self->{epp}->request($frame);
    # XXX Do stuff
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

    my $l = $login->can("lang") ? $login->lang : do {
        $option = $login->createElement("lang");
        $login->options->appendChild($option);
        $option;
    };
    $v->appendText($self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'version')->shift->firstChild->data);
    $l->appendText($self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'lang')->shift->firstChild->data);

    my $objects = $self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'objURI');
    while (my $object = $objects->shift) {
        next unless $object->firstChild->data =~ /^urn:ietf/;
        my $el = $login->createElement('objURI');
        $el->appendText($object->firstChild->data);
        $login->svcs->appendChild($el);
    }
    $objects = $self->{greeting}->getElementsByTagNameNS(EPP_XMLNS, 'extURI');
    my $svcext;
    if ($objects->size) {
        $svcext = $login->createElement('svcExtension');
        #$login->svcs->appendChild($svcext);
    }
    while (my $object = $objects->shift) {
        my $el = $login->createElement('extURI');
        $el->appendText($object->firstChild->data);
        $svcext->appendChild($el);
    }

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

package Net::EPP::Frame::Command::Update::Contact;
# Let's get monkeypatchy - steal stuff from ::Create::Contact because
# that makes setting up the appropriate elements easy when we need to
# add <contact:chg> stuff
sub addEl {
    my ($self, $name, $value) = @_;
    
    my $el = $self->createElement('contact:'.$name);
    $el->appendText($value) if defined($value);
    $self->chg->appendChild($el); # XXX Is this line correct?
        
    return $el;
}            

1;
