package Net::DomainRegistration::Simple;
use Socket;
use Carp;
use warnings;
use strict;

=head1 NAME

Net::DomainRegistration::Simple - Simple interface to various domain registrars

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

    use Net::DomainRegistration::Simple;
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

    my $c = {
        firstname => 'John',
        lastname  => 'Doe',
        city      => 'Portland',
        state     => 'Oregon',
        country   => 'US',
        address   => '555 Someplace Street',
        email     => 'john@example.com',
        phone     => '503-555-1212',
        postcode  => '20166-6503',
        company   => 'n/a'
    };

    $r->register(
        domain    => 'example.com',
        technical => $c,
        admin     => $c,
        billing   => $c
    );

=head1 FUNCTIONS

=head2 new

=cut

sub new {
    my ($self, %args) = @_;
    my $reg = $args{registrar};
    croak "No registrar specified!" unless $reg;
    eval  "require ${self}::$reg";
    if ($@ =~ /Can't locate/) { croak "Could not find a module to handle $reg"; }
    if ($@) { die $@ }
    my $o = bless { %args} , $self."::$reg";
    $o->_specialize();
    return $o;
}

=head2 register

=head2 renew

=head2 revoke

=head2 change_contact

=head2 set_nameservers

    $r->set_nameservers(
        domain => "example.com",
        nameservers => [ "ns0.manage.com", "ns1.manage.com" ]
    );

=cut

for my $s (qw(register renew revoke change_contact set_nameservers is_available)) {
    no strict;
    *$s = sub { my $thing = shift; die "$_ didn't provide a $s method!" };
}

sub _check_domain {
    my ($self, $args) = @_;
    croak "Need to specify a 'domain' argument" unless $args->{domain};
    $args->{domain} = lc $args->{domain};
    $args->{domain} =~ s/\.$//;
    # XXX More check
}

sub _check_register {
    my ($self, $args) = @_;
    $self->_check_domain($args);
    # XXX Check contact information
}

sub _check_renew {
    my ($self, $args) = @_;
    $self->_check_domain($args);
    croak "Must supply a 'years' argument" if !$args->{years};
}

sub _check_set_nameservers {
    my ($self, $args) = @_;
    $self->_check_domain($args);
    croak "Nameservers argument should be an array reference"
        unless ref $args->{nameservers} eq "ARRAY";
    for (@{$args->{nameservers}}) {
        $_ = lc $_;
        $_ .= "." unless /\.$/;
    }
}

sub _ipof {
    my ($self, $name) = @_;
    inet_ntoa(scalar gethostbyname($name));
}

=head1 AUTHOR

Simon Cozens, C<< <simon at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-net-domainregistration-simple at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Net-DomainRegistration-Simple>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::DomainRegistration::Simple


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Net-DomainRegistration-Simple>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Net-DomainRegistration-Simple>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Net-DomainRegistration-Simple>

=item * Search CPAN

L<http://search.cpan.org/dist/Net-DomainRegistration-Simple/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2010 Simon Cozens.

This program is released under the following license: Perl


=cut

1; # End of Net::DomainRegistration::Simple
