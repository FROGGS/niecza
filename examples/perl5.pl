eval(q:to/PERL5/,:lang<perl5>);
    print "Hel"."lo "; 
    PERL5
eval(q:to/PERL5/,:lang<perl5>);
    print "World\n";
    PERL5

eval(q:to/PERL5/,:lang<perl5>);
use strict;
use warnings;
package Foo;
sub baz {
    my ($self,$arg) = @_;
    print "Just another $arg\n";
    return 44;
}
sub new {
    bless {},"Foo";
}
PERL5
my $foo = eval(:lang<perl5>,'Foo->new');
say $foo.baz("Perl hacker");
say eval(:lang<perl5>,"125");
say eval(:lang<perl5>,"13.5");
say eval(:lang<perl5>,"'Hello there'");

