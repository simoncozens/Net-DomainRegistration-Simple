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
    my ($self, $schema) = @_;
    $self->{epp} = Net::EPP::Simple::Nominet->new(
        host => $self->_epp_host, 
        user => $self->{username},
        pass => $self->{password},
        debug => 1,
        specialSchema => $schema,
    );
}

sub _reset_connection {
    my ($self, $schema) = @_;

    return undef unless $self->{epp}->logout;
    return undef unless $self->_specialize( $schema );

    return 1;
}

=head2 is_available

    $nominet->is_available('example.co.uk');

Returns true is domain is available or false.

=cut

sub is_available {
    my ($self, $domain) = @_;
    $self->check($domain);
}

=head2 check

    $nominet->check('example.co.uk');
    $nominet->check(@listOfDomains);

Checks availability of domain(s). Returns a hash ref with each domain
set to 1 if available or 0 if not available.

=cut

sub check {
    my ($self, @domains) = @_;

    my $frame = Net::EPP::Frame::Command::Check::Domain->new();
    my $chk = $frame->getNode('domain:check');
    $chk->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0');
    $chk->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0 nom-domain-2.0.xsd');

    foreach (@domains) {
        $frame->addDomain($_);
    }

    my $answer = $self->{epp}->request($frame);
    return undef unless $answer;
    my $code = $self->{epp}->_get_response_code($answer);
    return undef unless $code == 1000;

    my $results = $answer->getElementsByTagName('domain:name');
    return undef unless $results;
    
    if ( scalar @domains > 1 ) {
        my $rv = { };
        while (my $r = $results->shift) {
            $rv->{$r->textContent} = $r->getAttribute('avail');
        }
        return $rv;
    }
    else {
        return $results->shift->getAttribute('avail');
    }
}

sub domain_info {
    my ($self, $domain) = @_;

    my $frame = Net::EPP::Frame::Command::Info::Domain->new();

    my $dn = $frame->getNode('domain:info');
    
    $dn->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0'); 
    $dn->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0 nom-domain-2.0.xsd');

    $frame->setDomain($domain);

    my $answer = $self->{epp}->request($frame);
    return undef unless $answer;
    my $code = $self->{epp}->_get_response_code($answer);

    croak "Nominet error $code" if $code > 1999;

    my $infData = $answer->getNode('domain:infData');

    return $self->_domain_infData_to_hash($infData);
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

    my $info = $self->domain_info($args{domain}) or return;
    my $d = $info->{exDate};
    $d =~ s/T.*//; # Avoid "garbage at end of string";
    my $t = Time::Piece->strptime($d, "%Y-%m-%d");
    return if $t - 180*ONE_DAY > Time::Piece->new;
    #XXX
    
    my $frame = Net::EPP::Frame::Command::Renew::Domain->new;

    my $r = $frame->getNode('domain:renew');
    $r->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0'); 
    $r->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0 nom-domain-2.0.xsd');

    $frame->setDomain($args{domain});
    $frame->setPeriod(2);
    # Grab the new exDate
    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);
    return if $code > 1999;
    my $node = $answer->getNode("domain:exDate");
    return unless $node;
    $d = $node->textContent;
    $d =~ s/T.*//;
    return $d;
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

=head2 list

    $nominet->list( 'month' => '2010-01' fields => 'all' );

Returns a list of domains, either registered in a given month if called
with the "month" parameter or expiring in a given month if called with the
"expiry" parameter. If called with the fields parameter set to "all" then
full information for each domain is returned, otherwise just the domain
name.

Parameters:

    month : either this or expiry must be given
    expiry : either this or month must be given
    fields : (optional) may be set to "none" or "all" or omitted entirely

Returns:

If fields parameter is omitted or set to "none" returns an array each 
element of which is a domain name either registered in or expiring in
the given month.

If the fields parameter is set to "all" returns an array each element of
which is a hash reference containing full information (as per domain_info
method) for each domain registered in or expiring in the given month.

=cut

sub list {
    my ($self, %args) = @_;
    $self->_check_list(\%args);

    # We need to create the frame from scratch so we'll use the base
    # command frame, clean out the existing elements and build it 
    # ourselves.

    my $frame = Net::EPP::Frame::Command->new();

    my $c = $frame->getNode('command');

    my $n = $frame->getNode('net');
    $c->removeChild($n);
    my $id = $frame->getNode('clTRID');
    $c->removeChild($id);

    my $info = $frame->createElement('info');

    my $dl = $frame->createElement('domain:list');
    $dl->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0'); 
    $dl->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0 nom-domain-2.0.xsd');

    for (qw/month expiry fields/) {
        next unless $args{$_};
        my $f = $frame->createElement('domain:'.$_);
        $f->appendText($args{$_});
        $dl->addChild($f);
    }

    $info->addChild($dl);
    $c->addChild($info);

    $id = $frame->createElement('clTRID');
    $c->addChild($id);

    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);
    return undef if $code > 1999; # XXX Should be a croak?

    my @domains = ();

    my $list = $answer->getNode('domain:listData');

    my $domains = $list->getElementsByTagName('domain:infData');
    if ( $domains ) {
        while ( my $domain = $domains->shift ) {
            push @domains, $self->_domain_infData_to_hash($domain);
        }
    }
    else {
        my @d = $list->getElementsByTagName('domain:name');
        for (@d) {
            push @domains, $_->textContent;
        }
    }
    return \@domains;
}

=head2 taglist

    $nominet->taglist();

Returns an array of all currently active tags. Each array element is a 
hash reference as follows:

    registrar-tag : TAG
    name : Name of tag holder
    trad-name : (optional) Trading name
    handshake : Y if tag holder requires a handshake to move domains to
                the tag or N if they do not

=cut

sub taglist {
    my ($self) = @_;

    return undef unless $self->_reset_connection( 'nom-tag' );

    my $frame = Net::EPP::Frame::Command->new();

    my $c = $frame->getNode('command');

    my $n = $frame->getNode('net');
    $c->removeChild($n);
    my $id = $frame->getNode('clTRID');
    $c->removeChild($id);

    my $info = $frame->createElement('info');
    my $tl = $frame->createElement('tag:list');
    $tl->setAttribute('xmlns:tag', 'http://www.nominet.org.uk/epp/xml/nom-tag-1.0'); 
    $tl->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-tag-1.0 nom-tag-1.0.xsd');

    $info->addChild($tl);
    $c->addChild($info);

    $id = $frame->createElement('clTRID');
    $c->addChild($id);

    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);
    return undef if $code > 1999; # XXX Should be a croak?

    my @rv = ();
    my $tags = $answer->getElementsByTagName('tag:infData');
    while (my $tag = $tags->shift) {
        my $t = { };
        my @c = $tag->getChildrenByTagName('*');
        foreach (@c) { 
            $t->{$_->nodeName} = $_->textContent;
        }
        push @rv, $t;
    }

    return undef unless $self->_reset_connection;

    return \@rv;
}

sub poll {
    my ($self) = @_;
    my $frame = Net::EPP::Frame::Command::Poll::Req->new();
    my $answer = $self->{epp}->request($frame);

    my $code = $self->{epp}->_get_response_code($answer);
    return undef if $code > 1999; # XXX Should be a croak?

    # XXX Determine action to take based upon the notification type
    my $res = $answer->getNode('resData');
    my @notice = $res->childNodes;

    my %rv = ();
    SWITCH: for ( $notice[1]->nodeName ) {
        /^abuse-feed:infData$/  && do { %rv = $self->_abuse_notice($answer);  last SWITCH; };
        /^account:infData$/     && do { %rv = $self->_amended_account_notice($answer); last SWITCH; };
        /^n:cancData$/          && do { %rv = $self->_domain_cancelled_notice($answer); last SWITCH; };
        /^n:relData$/           && do { %rv = $self->_domains_released_notice($answer); last SWITCH; };
        /^n:rcData$/            && do { %rv = $self->_handshake_request_notice($answer); last SWITCH; };
        /^n:hostCancData$/      && do { %rv = $self->_host_cancelled_notice($answer); last SWITCH; };
        /^n:processData$/       && do { %rv = $self->_poor_quality_notice($answer); last SWITCH; };
        /^n:suspData$/          && do { %rv = $self->_suspended_domain_notice($answer); last SWITCH; };
        /^domain:creData$/      && do { %rv = $self->_referal_accepted_notice($answer); last SWITCH; };
        /^domain:failData$/     && do { %rv = $self->_referal_rejected_notice($answer); last SWITCH; };
        /^n:trnData$/           && do { %rv = $self->_registrant_change_notice($answer); last SWITCH; };
        /^n:rcData$/            && do { %rv = $self->_registrar_change_notice($answer); last SWITCH; };
        { croak "Unrecognised Nominet notice"; };
    }

    return \%rv;
}

=head2 

    $nominet->transfer( domain => 'example.co.uk',
                        tag => 'NEWTAG',
                        account => 'abcd123' );

Releases a domain to the Nominet registrar tag specified and, optionally, 
to the specified account.

Parameters:
    domain (mandatory)
    tag (mandatory)
    account

Returns 1000 if the domain transfer has completed or 1001 if the
receiving Nominet registrar's processes require them to accept the 
transfer before it can complete.

=cut

sub transfer {
    my ($self, %args) = @_;
    $self->_check_transfer(\%args);

    my $frame = Net::EPP::Frame::Command::Transfer::Domain->new();

    my $transfer = $frame->getNode('domain:transfer');

    $transfer->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0'); 
    $transfer->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-domain-2.0 nom-domain-2.0.xsd');

    $frame->setOp('request');
    $frame->setDomain($args{domain});

    my $tag = $frame->createElement('domain:registrar-tag');
    $tag->appendText($args{tag});
    $transfer->addChild($tag);

    if ( $args{account} ) {
        my $a = $frame->createElement('domain:account-id');
        $a->appendText($args{account});

        my $e = $frame->createElement('domain:account');
        $e->addChild($a);
        $transfer->addChild($e);
    }

    my $answer = $self->{epp}->request($frame);

    my $code = $self->{epp}->_get_response_code($answer);
    return undef if $code > 1999;
    return $code;
}

=head2 handshake

    $nominet->handshake( caseid => '10001', handshake => 'approve');

Parameters: (all are mandatory)

    caseid : The case ID for the handshake request as obtained from the 
    poll() method.
    handshake: Either 'approve' or 'reject'

Returns an array listing the domains accepted or rejected by the handshake

=cut

sub handshake {
    my ($self, %args) = @_;
    $self->_check_handshake(\%args);

    my $frame = Net::EPP::Frame::Command::Transfer::Domain->new();
    $frame->setOp($args{handshake});

    my $transfer = $frame->getNode('transfer');

    my $t = $frame->getNode('domain:transfer');
    $transfer->removeChild($t);

    my $c = $frame->createElement('n:Case');
    $c->setAttribute('xmlns:domain', 'http://www.nominet.org.uk/epp/xml/nom-notifications-2.0');
    $c->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-notifications-2.0 nom-notifications-2.0.xsd');

    my $cid = $frame->createElement('n:case-id');
    $cid->appendText($args{caseid});

    $c->addChild($cid);
    $transfer->addChild($c);

    my $answer = $self->{epp}->request($frame);

    my $code = $self->{epp}->_get_response_code($answer);

    # XXX This really should croak as it's an error condition
    return undef if $code > 1999;

    my $dl = $answer->getNode('n:domainList');
    return undef unless $dl;
    my $dc = $dl->getElementsByLocalName('n:no-domains');
    return undef unless $dc->textContent > 0;

    my @domains = $dl->getElementsByLocalName('n:domain-name');

    my @rv = ();
    for (@domains) {
        push @rv, $_->textContent;
    }

    return \@rv;
}

=head2 create_reseller

    $nominet->create_reseller( reference => 'RESELLER1', 
                               tradingName => 'Reseller 1 Ltd', 
                               url => 'http://www.example.com/' );

Creates a new reseller. Returns 1 on success or undef on failure.

Parameters:

    reference : your unique reference for the new reseller
    tradingName : trading name of the reseller
    url : URL for the reseller that customers will be directed to for 
          support or further information
    email : email contact for the reseller
    voice : telephone number contact for the reseller

reference, tradingName and url are required. Either email or voice must 
also be supplied

Note that reference may only contain upper case characters A-Z, digits 0-9
and hyphens.

See http://www.nominet.org.uk/registrars/resellerdata/supplyresellerdata/

=cut

sub create_reseller {
    my ($self, %args) = @_;
    $self->_check_create_reseller(\%args);

    $self->_reset_connection('nom-reseller');

    my $frame = Net::EPP::Frame::Command::Create->new();
    my $c = $frame->getNode('create');

    my $rc = $frame->createElement('reseller:create');

    $rc->setAttribute('xmlns:reseller', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0');
    $rc->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0 nom-reseller-1.0.xsd');

    for my $name (qw/reference tradingName url email voice/) {
        next unless $args{$name};
        my $e = $frame->createElement('reseller:'.$name);
        $e->appendText($args{$name});
        $rc->addChild($e);
    }

    $c->addChild($rc);

    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);
    $self->_reset_connection();

    return undef unless $code == 1000;
    return 1;
}

=head2 delete_reseller

    $nominet->delete_reseller( reference => 'RESELLER1' );

Delete a reseller.

Parameters:

    reference : your unique reference for the reseller

Returns 1 on success or undef on failure.

=cut

sub delete_reseller {
    my ($self, %args) = @_;
    $self->_check_delete_reseller(\%args);

    $self->_reset_connection('nom-reseller');

    my $frame = Net::EPP::Frame::Command::Delete->new();

    my $d = $frame->getNode('delete');
    my $rd = $frame->createElement('reseller:delete');

    $rd->setAttribute('xmlns:reseller', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0');
    $rd->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0 nom-reseller-1.0.xsd');

    my $e = $frame->createElement('reseller:reference');
    $e->appendText($args{'reference'});
    $rd->addChild($e);

    $d->addChild($rd);

    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);
    
    $self->_reset_connection();

    return undef unless $code == 1000;
    return 1;
}

=head2 reseller_info

Returns a hash reference containing details of the reseller.

Parameters:

    reference: your unique reference for the reseller

Returns:

    reference: your unique reference for the reseller
    tradingName : Name of the reseller
    url : URL for the reseller that customers will be directed to for 
          support or further information
    email : email contact for the reseller
    voice : telephone number contact for the reseller

=cut

sub reseller_info {
    my ($self, %args) = @_;
    $self->_check_reseller_info(\%args);

    my %rv = ();
    $self->_reset_connection('nom-reseller');

    my $frame = Net::EPP::Frame::Command::Info->new();

    my $i = $frame->getNode('info');
    my $ri = $frame->createElement('reseller:info');

    $ri->setAttribute('xmlns:reseller', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0');
    $ri->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0 nom-reseller-1.0.xsd');

    my $e = $frame->createElement('reseller:reference');
    $e->appendText($args{'reference'});
    $ri->addChild($e);

    $i->addChild($ri);

    my $answer = $self->{epp}->request($frame);
    my $code = $self->{epp}->_get_response_code($answer);

    $self->_reset_connection();

    return undef unless $code == 1000;

    my $data = $answer->getNode('reseller:infData');

    return $self->_reseller_infData_to_hash($data);
}

=head2 reseller_list

    $nominet->reseller_list();

Returns an array ref of all resellers. If only reference is returned
the array elements will be the reference(s) for the reseller(s). If
more fields are returned the element will be a hash ref containing
the requested data.

Parameters:

    fields : (optional) if supplied specifies which fields to return if
             not specified only the reference will be returned.

=cut

sub reseller_list {
    my ( $self, %args ) = @_;

    $self->_reset_connection('nom-reseller');
    my $frame = Net::EPP::Frame::Command->new();

    my $c = $frame->getNode('command');

    my $n = $frame->getNode('net');
    $c->removeChild($n);
    my $id = $frame->getNode('clTRID');
    $c->removeChild($id);

    my $info = $frame->createElement('info');

    my $l = $frame->createElement('reseller:list');
    $l->setAttribute('xmlns:reseller', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0'); 
    $l->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0 nom-reseller-1.0.xsd');

    $l->setAttribute('fields', $args{fields}) if $args{fields};

    $info->addChild($l);
    $c->addChild($info);

    $id = $frame->createElement('clTRID');
    $c->addChild($id);

    my $answer = $self->{epp}->request($frame);
    
    $self->_reset_connection();

    my $code = $self->{epp}->_get_response_code($answer);
    return undef unless $code == 1000;

    my $resellers = $answer->getElementsByTagName('reseller:infData');

    my @rv = ();

    if ( $resellers ) {
        while (my $r = $resellers->shift) {
            push @rv, $self->_reseller_infData_to_hash($r);
        }
    }
    else {
        my @resellers = $answer->getElementsByTagName('reseller:reference');
        for my $r (@resellers) {
            push @rv, $r->textContent;
        }
    }

    return \@rv;
}

=head2 reseller_update

    $nominet->reseller_update( reference => 'RESELLER1',
                               tradingName => 'My Reseller Ltd',
                               url => 'http://www.example.co.uk/',
                               email => 'support@example.co.uk',
                               voice => '+44.02079460123' );

Updates the reseller information. Returns true on success or undef.

Parameters:

    reference : (required) the unique reference for the reseller
    tradingName : (optional) the name of the reseller
    url : (optional) the URL for the reseller
    email : (optional*) email contact for the reseller
    voice : (optional*) telephone number contact for the reseller

* if either the email or voice parameters are omitted any value currently
stored for that parameter will be cleared. At least one of either email
or voice must be supplied.

=cut

sub reseller_update {
    my ($self, %args) = @_;
    $self->_check_reseller_update(\%args);

    $self->_reset_connection('nom-reseller');

    my $frame = Net::EPP::Frame::Command::Update->new();

    my $update = $frame->getNode('update');

    my $u = $frame->createElement('reseller:update');
    $u->setAttribute('xmlns:reseller', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0');
    $u->setAttribute('xsi:schemaLocation', 'http://www.nominet.org.uk/epp/xml/nom-reseller-1.0 nom-reseller-1.0.xsd');

    foreach my $name (qw/reference tradingName url email voice/) {
        next unless $args{$name};
        my $e = $frame->createElement('reseller:'.$name);
        $e->appendText($args{$name});
        $u->addChild($e);
    }

    $update->addChild($u);

    my $answer = $self->{epp}->request($frame);
    
    $self->_reset_connection();

    my $code = $self->{epp}->_get_response_code($answer);
    return undef unless $code == 1000;
    return 1;
}

# The following methods are called by the poll method to handle each type
# of notice from Nominet. Each method returns a hash with a "notice" key
# and additional keys specific to the notice type. See the POD for each
# method below for details.

=head2 _abuse_notice

Returns a hash with the following keys, corresponding to the data passed
by Nominet's Abuse notification:

    notice : abuse
    report => {
        key :
        activity :
        source :
        hostname :
        url :
        date :
        ip :
        nameserver :
        dnsAdmin :
    }

=cut

sub _abuse_notice {
    my ($self, $res) = @_;

    my %rv = ();
    $rv{notice} = 'abuse';
    for (qw/ key activity source hostname url date ip nameserver dnsAdmin
             target wholeDomain/) {
        $rv{'report'}{$_} = $res->getNode('abuse-feed:'.$_)->textContent;
    }
    return %rv;
}

=head2 _amended_account_notice

=cut

sub _amended_account_notice {
    my ($self, $res) = @_;

    my %rv = ();
    
    $rv{notice} = 'amendAccount';
    for (qw/roid name type opt-out street city county postcode country 
            clID crDate upDate/) {
        $rv{'account'}{$_} = $res->getNode('account:'.$_)->textContent;
    }
    return %rv;
}

=head2 _domain_cancelled_notice

Returns a hash as follows:

    notice : domainCancelled
    domain : example.co.uk

=cut

sub _domain_cancelled_notice {
    my ($self, $res) = @_;
    my %rv = ();

    $rv{notice} = 'domainCancelled';
    $rv{domain} = $res->getNode('n:domain-name')->textContent;
    
    return %rv;
}

=head2 _domains_released_notice

Returns a hash as follows:

    notice : released
    newtag : NOMINET_TAG_OF_NEW_REGISTRAR
    oldtag : NOMINET_TAG_OF_OLD_REGISTRAR
    domains : ( 'example1.co.uk', 'example2.co.uk', ... )

If there are no domains affected returns undef

=cut

sub _domains_released_notice {
    my ($self, $res) = @_;
    my %rv = ();

    if ( $self->_get_message($res) =~ /Released/ ) {
        $rv{notice} = 'released';
    }
    else {
        $rv{notice} = 'rejected';
    }
    $rv{newtag} = $res->getNode('n:registrar-tag')->textContent;
    $rv{oldtag} = $res->getNode('n:from')->textContent;
    
    my $domains = $res->getElementsByLocalName('domain:name');

    # If there are no domains there is no point
    return unless $domains;

    while (my $d = $domains->shift) {
        push @{$rv{domains}}, $d->textContent;
    }

    return %rv;
}

=head2 _handshake_request_notice

=cut

sub _handshake_request_notice {
    my ($self, $res) = @_;
    my %rv = ();

    $rv{notice} = 'handshakeRequest';

    # XXX Get various infos
    
    return %rv;
}

=head2 _host_cancelled_notice

Returns a hash as follows:

    notice : hostCancelled
    hosts : ( 'host.example.co.uk', 'host2.example.co.uk', ... )
    domains : ( 'example.co.uk', 'example2.co.uk', ... )

=cut

sub _host_cancelled_notice {
    my ($self, $res) = @_;
    my %rv = ();

    $rv{notice} = 'hostCancelled';
    my $hosts = $res->getElementsByLocalName('n:hostObj');
    while (my $host = $hosts->shift) {
        push @{$rv{hosts}}, $host->textContent;
    }

    my $domains = $res->getElementsByLocalName('domain:name');
    while (my $d = $domains->shift) {
        push@{$rv{domains}}, $d->textContent;
    }
    return %rv;
}

=head2 _poor_quality_notice

=cut

sub _poor_quality_notice {
    my ($self, $res) = @_;
    my %rv = ();

    $rv{notice} = 'poorQuality';

    $rv{reason} = $res->getNode('n:processType')->textContent;

    if ( $res->getNode('n:suspendDate') ) {
        $rv{suspendDate} = $res->getNode('n:suspendDate')->textContent;
    }
    if ( $res->getNode('n:cancelDate') ) {
        $rv{deleteDate} = $res->getNode('n:cancelDate')->textContent;
    }

    if ( my $infData = $res->getNode('account:infData') ) {
        $rv{account} = $self->_account_infData_to_hash($infData);
    }

    my $domains = $res->getElementsByLocalName('domain:name');
    while (my $d = $domains->shift) {
        push@{$rv{domains}}, $d->textContent;
    }

    return %rv;
}

=head _suspended_domain_notice

Returns a hash as follows:

    notice : domainSuspended
    reason : Reason domain(s) suspended
    date : Date domain(s) will be cancelled and deleted
    domains : ( 'example.co.uk', 'example.org.uk', ... )

=cut

sub _suspended_domain_notice {
    my ( $self, $res ) = @_;
    my %rv = ();

    $rv{notice} = 'domainSuspended';

    $rv{reason} = $res->getNode('n:reason')->textContent;
    $rv{date} = $res->getNode('n:cancelDate')->textContent;

    my $domains = $res->getElementsByLocalName('domain:name');
    while (my $d = $domains->shift) {
        push@{$rv{domains}}, $d->textContent;
    }

    return %rv;
}

sub _referal_accepted_notice {
    my ($self, $res ) = @_;
    my %rv = ();

    $rv{notice} = 'referralAccept';
    $rv{domain} = $res->getNode('domain:name')->textContent;

    for (qw/crDate exDate/) {
        $rv{$_} = $res->getNode('domain:'.$_)->textContent;
    }

    return %rv;
}

sub _referal_rejected_notice {
    my ($self, $res ) = @_;
    my %rv = ();

    $rv{notice} = 'referralReject';
    $rv{domain} = $res->getNode('domain:name')->textContent;
    $rv{reason} = $res->getNode('domain:reason')->textContent;

    return %rv;
}

sub _registrant_change_notice {
    my ($self, $res ) = @_;
    my %rv = ();

    $rv{notice} = 'registrantChange';
    $rv{old_account} = $res->getNode('n:old-account-id')->textContent;
    $rv{new_account} = $res->getNode('n:account-id')->textContent;

    my $infData = $res->getNode('account:infData');
    $rv{account} = $self->_account_infData_to_hash($infData);

    my $domains = $res->getElementsByTagName('domain:simpleInfData');
    while (my $domain = $domains->shift) {
        push @{$rv{domains}}, $self->_domain_infData_to_hash($domain);
    }

    return %rv;
}

sub _registrar_change_notice {
    my ($self, $res ) = @_;
    my %rv = ();

    $rv{notice} = 'registrarChange';
    $rv{newtag} = $res->getNode('n:registrar-tag')->textContent;

    my $infData = $res->getNode('account:infData');
    $rv{account} = $self->_account_infData_to_hash($infData);

    my $domains = $res->getElementsByTagName('domain:simpleInfData');
    while (my $domain = $domains->shift) {
        push @{$rv{domains}}, $self->_domain_infData_to_hash($domain);
    }
    return %rv;
}

sub _domain_infData_to_hash {
    my ($self, $infData) = @_;

    my $hash = { };
    $hash = $self->_account_infData_to_hash($infData);

    $hash->{registrant} = $hash->{account}->{name} if $hash->{account}->{name};

    foreach my $name (qw/name clID crID crDate upID upDate exDate/) {
        next unless $hash->{$name} = $infData->getElementsByTagName('domain:'.$name)->shift->textContent;
    }
    $hash->{status} = $infData->getChildrenByTagName('domain:reg-status')->shift->textContent;

    my @ns = $infData->getElementsByTagName('domain:host');
    foreach my $host ( @ns ) {
        my $name = $host->getChildrenByTagName('domain:hostName');
        my $addr = $host->getChildrenByTagName('domain:hostAddr');

        if ( $addr ) {
            push @{$hash->{ns}}, { 
                name => $name->shift->textContent,
                addr => $addr->shift->textContent,
                version => addr->getAttribute('ip')
            };
        }
        else {
            push @{$hash->{ns}}, { name => $name->shift->textContent };
        }
    }

    return $hash;
}

sub _account_infData_to_hash {
    my ($self, $infData) = @_;
    my $hash = { };

    foreach my $name (qw/roid name trad-name type opt-out clID 
                         crID crDate upID upDate/) {
        my $node = $infData->getElementsByTagName('account:'.$name);
        next unless $node;
        next unless $hash->{account}->{$name} = $node->shift->textContent;
    }

    my $address = $infData->getElementsByTagName('account:addr');
    my @addr = $address->shift->getChildrenByTagName('*');
    foreach ( @addr ) {
        my $name = $_->nodeName;
        $name =~ s/account:(.*)/$1/;
        $hash->{account}->{addr}->{$name} = $_->textContent;
    }

    my $contacts = $infData->getElementsByTagName('account:contact');
    while ( my $c = $contacts->shift ) {
        my $type = $c->getAttribute('type');
        my @inf = $c->getChildrenByTagName('contact:infData');
        my @contact = $inf[0]->getChildrenByTagName('*');
        my $ch = {};
        foreach (@contact) {
            my $name = $_->nodeName;
            $name =~ s/contact:(.*)/$1/;
            $ch->{$name} = $_->textContent;
        }
        if ( $type ) {
            push @{$hash->{account}->{contact}->{$type}}, $ch;
        }
        else {
            push @{$hash->{account}->{contact}}, $ch;
        }
    }

    return $hash;
}

sub _reseller_infData_to_hash {
    my ($self, $infData) = @_;
    my $hash = { };

    for my $name (qw/reference tradingName url email voice/) {
        my $node = $infData->getElementsByTagName('reseller:'.$name);
        next unless $node;
        $hash->{$name} = $node->shift->textContent;
    }

    return $hash;
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
    $self->{timeout}    = (int($params{timeout}) > 0 ? $params{timeout} : 15);

    bless($self, $package);

    return undef unless $self->login(%params);
    return $self;
}

sub login {
    my ( $self, %params ) = @_;

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

    my %schemas = ();
    while (my $object = $objects->shift) {
        # Don't ignore the Nominet schemas - we need them!
        if ( $object->firstChild->data =~ /^http:\/\/www.nominet.org.uk\/epp\/xml\/(.*)-([\d\.]+)/ ) {
            next if $schemas{$1} > $2; # XXX we only want the latest one
            $schemas{$1} = $2;
            next;
        }
        # We only need the host schema from the non-Nominet ones
        next unless $object->firstChild->data =~ /^urn:ietf:params:xml:ns:host/;

        my $el = $login->createElement('objURI');
        $el->appendText($object->firstChild->data);
        $login->svcs->appendChild($el);
    }

    for ('nom-domain', 
         'nom-notifications',
         'nom-abuse-feed',
        ) {
        next unless $schemas{$_};
        my $el = $login->createElement('objURI');
        $el->appendText('http://www.nominet.org.uk/epp/xml/'.$_ . "-" . $schemas{$_});
        $login->svcs->appendChild($el);
    }

    if ( $params{specialSchema} ) {
        # XXX Remove al existing objURI elements and pass only nom-tag
        my $objs = $login->getElementsByTagName('objURI');
        while ( my $obj = $objs->shift) {
            $login->svcs->removeChild($obj);
        }

        my $el = $login->createElement('objURI');
        $el->appendText('http://www.nominet.org.uk/epp/xml/'.$params{specialSchema}.'-'.$schemas{$params{specialSchema}});
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

    return 1;
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
