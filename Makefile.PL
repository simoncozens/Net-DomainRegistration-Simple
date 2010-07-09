use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Net::DomainRegistration::Simple',
    AUTHOR              => q{Simon Cozens <simon@cpan.org>},
    VERSION_FROM        => 'lib/Net/DomainRegistration/Simple.pm',
    ABSTRACT_FROM       => 'lib/Net/DomainRegistration/Simple.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'Perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Carp' => 0,
        'Net::EPP' => 0,
        'Time::Piece' => 0,
        'Time::Seconds' => 0,
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Net-DomainRegistration-Simple-*' },
);
