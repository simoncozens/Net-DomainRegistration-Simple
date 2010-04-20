#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Net::DomainRegistration::Simple' );
}

diag( "Testing Net::DomainRegistration::Simple $Net::DomainRegistration::Simple::VERSION, Perl $], $^X" );
