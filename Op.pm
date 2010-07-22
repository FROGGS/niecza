use strict;
use warnings;
use 5.010;

use CgOp;

{
    package Op;
    use Moose;

    sub paren { shift }

    sub zyg { }

    sub local_decls {
        my ($self) = shift;
        map { $_->local_decls } $self->zyg;
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::CgOp;
    use Moose;
    extends 'Op';

    has op => (is => 'ro', required => 1);

    sub code { $_[0]->op }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::StatementList;
    use Moose;
    extends 'Op';

    has children => (isa => 'ArrayRef[Op]', is => 'ro', required => 1);
    sub zyg { @{ shift()->children } }

    sub code {
        my ($self, $body) = @_;
        my @ch = map { $_->code($body) } @{ $self->children };
        # XXX should be Nil or something
        my $end = @ch ? pop(@ch) : CgOp::wrap(CgOp::null('object'));

        CgOp::prog((map { CgOp::sink($_) } @ch), $end);
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::CallSub;
    use Moose;
    extends 'Op';

    has invocant    => (isa => 'Op', is => 'ro', required => 1);
    has positionals => (isa => 'ArrayRef[Op]', is => 'ro',
        default => sub { [] });
    # non-parenthesized constructor
    has splittable_pair => (isa => 'Bool', is => 'rw', default => 0);
    has splittable_parcel => (isa => 'Bool', is => 'rw', default => 0);
    sub zyg { $_[0]->invocant, @{ $_[0]->positionals } }

    sub paren {
        my ($self) = @_;
        Op::CallSub->new(invocant => $self->invocant,
            positionals => $self->positionals);
    }

    sub code {
        my ($self, $body) = @_;
        CgOp::subcall(CgOp::fetch($self->invocant->code($body)),
            map { $_->code($body) } @{ $self->positionals });
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::CallMethod;
    use Moose;
    extends 'Op';

    has receiver    => (isa => 'Op', is => 'ro', required => 1);
    has positionals => (isa => 'ArrayRef[Op]', is => 'ro',
        default => sub { [] });
    has name        => (isa => 'Str', is => 'ro', required => 1);
    sub zyg { $_[0]->receiver, @{ $_[0]->positionals } }

    sub code {
        my ($self, $body) = @_;
        CgOp::methodcall($self->receiver->code($body),
            $self->name, map { $_->code($body) } @{ $self->positionals });
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::GetSlot;
    use Moose;
    extends 'Op';

    has object => (isa => 'Op', is => 'ro', required => 1);
    has name   => (isa => 'Str', is => 'ro', required => 1);
    sub zyg { $_[0]->object }

    sub code {
        my ($self, $body) = @_;
        CgOp::varattr($self->name, CgOp::fetch($self->object->code($body)));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

# or maybe we should provide Op::Let and let Actions do the desugaring?
{
    package Op::CallMetaMethod;
    use Moose;
    extends 'Op';

    has receiver    => (isa => 'Op', is => 'ro', required => 1);
    has positionals => (isa => 'ArrayRef[Op]', is => 'ro',
        default => sub { [] });
    has name        => (isa => 'Str', is => 'ro', required => 1);
    sub zyg { $_[0]->receiver, @{ $_[0]->positionals } }

    sub code {
        my ($self, $body) = @_;
        CgOp::let($self->receiver->code($body), sub {
            CgOp::methodcall(CgOp::newscalar(CgOp::how(CgOp::fetch($_[0]))),
                $self->name, $_[0], map { $_->code($body) }
                    @{ $self->positionals })});
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::Interrogative;
    use Moose;
    extends 'Op';

    has receiver    => (isa => 'Op', is => 'ro', required => 1);
    has name        => (isa => 'Str', is => 'ro', required => 1);
    sub zyg { $_[0]->receiver }

    sub code {
        my ($self, $body) = @_;
        my $c = CgOp::fetch($self->receiver->code($body));
        given ($self->name) {
            when ("HOW") {
                $c = CgOp::how($c);
            }
            when ("WHAT") {
                $c = CgOp::getfield('typeObject',
                    CgOp::getfield('klass', CgOp::cast('DynObject', $c)));
            }
            default {
                die "Invalid interrogative $_";
            }
        }
        CgOp::newscalar($c);
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::Yada;
    use Moose;
    extends 'Op';

    has kind => (isa => 'Str', is => 'ro', required => 1);

    sub code {
        my ($self, $cg, $body) = @_;

        CgOp::prog(
            CgOp::subcall(
                CgOp::fetch(CgOp::scopedlex("&warn")),
                CgOp::string_var(">>>Stub code executed<<<")
            ),
            CgOp::subcall(
                CgOp::fetch(CgOp::scopedlex("&exit")),
            ),
        );
    }
}

{
    package Op::ShortCircuit;
    use Moose;
    extends 'Op';

    has kind => (isa => 'Str', is => 'ro', required => 1);
    has args => (isa => 'ArrayRef[Op]', is => 'ro', required => 1);
    sub zyg { @{ $_[0]->args } }

    sub red2 {
        my ($self, $sym, $o2) = @_;
        given ($self->kind) {
            when ("&&") {
                return CgOp::ternary(CgOp::unbox('Boolean', CgOp::fetch(
                        CgOp::methodcall($sym, 'Bool'))), $o2, $sym);
            }
            when ("||") {
                return CgOp::ternary(CgOp::unbox('Boolean', CgOp::fetch(
                        CgOp::methodcall($sym, 'Bool'))), $sym, $o2);
            }
            when ("andthen") {
                return CgOp::ternary(CgOp::unbox('Boolean', CgOp::fetch(
                        CgOp::methodcall($sym, 'defined'))), $o2, $sym);
            }
            when ("//") {
                return CgOp::ternary(CgOp::unbox('Boolean', CgOp::fetch(
                        CgOp::methodcall($sym, 'defined'))), $sym, $o2);
            }
            default {
                die "That's not a sensible short circuit, now is it?";
            }
        }
    }

    sub code {
        my ($self, $body) = @_;

        my @r = reverse @{ $self->args };
        my $acc = (shift @r)->code($body);

        for (@r) {
            $acc = CgOp::let($_->code($body), sub { $self->red2($_[0], $acc) });
        }

        $acc;
    }
}

{
    package Op::StringLiteral;
    use Moose;
    extends 'Op';

    has text => (isa => 'Str', is => 'ro', required => 1);

    sub code {
        my ($self, $body) = @_;
        CgOp::string_var($self->text);
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::Conditional;
    use Moose;
    extends 'Op';

    has check => (isa => 'Op', is => 'ro', required => 1);
    has true  => (isa => 'Maybe[Op]', is => 'ro', required => 1);
    has false => (isa => 'Maybe[Op]', is => 'ro', required => 1);

    sub zyg { grep { defined } $_[0]->check, $_[0]->true, $_[0]->false }

    sub code {
        my ($self, $body) = @_;

        CgOp::ternary(
            CgOp::unbox('Boolean',
                CgOp::fetch(
                    CgOp::methodcall($self->check->code($body), "Bool"))),
            # XXX use Nil
            ($self->true ? $self->true->code($body) :
                CgOp::null('Variable')),
            ($self->false ? $self->false->code($body) :
                CgOp::null('Variable')));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::WhileLoop;
    use Moose;
    extends 'Op';

    has check => (isa => 'Op', is => 'ro', required => 1);
    has body  => (isa => 'Op', is => 'ro', required => 1);
    has once  => (isa => 'Bool', is => 'ro', required => 1);
    has until => (isa => 'Bool', is => 'ro', required => 1);
    sub zyg { $_[0]->check, $_[0]->body }

    sub code {
        my ($self, $cg, $body) = @_;

        CgOp::prog(
            CgOp::whileloop($self->until, $self->once,
                CgOp::unbox('Boolean',
                    CgOp::fetch(
                        CgOp::methodcall($self->check->code($body), "Bool"))),
                CgOp::sink($self->body->code($body))),
            CgOp::null('Variable'));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

# only for state $x will start and START{} in void context, yet
{
    package Op::Start;
    use Moose;
    extends 'Op';

    # possibly should use a raw boolean somehow
    has condvar => (isa => 'Str', is => 'ro', required => 1);
    has body => (isa => 'Op', is => 'ro', required => 1);
    sub zyg { $_[0]->body }

    sub code {
        my ($self, $body) = @_;

        CgOp::ternary(
            CgOp::unbox('Boolean',
                CgOp::fetch(
                    CgOp::methodcall(CgOp::scopedlex($self->condvar), "Bool"))),
            CgOp::wrap(CgOp::null('object')),
            CgOp::prog(
                CgOp::assign(CgOp::scopedlex($self->condvar),
                    CgOp::box('Bool', CgOp::bool(1))),
                $self->body->code($body)));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}


{
    package Op::Num;
    use Moose;
    extends 'Op';

    has value => (isa => 'Num', is => 'ro', required => 1);

    sub code {
        my ($self, $body) = @_;
        CgOp::box('Num', CgOp::double($self->value));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::Bind;
    use Moose;
    extends 'Op';

    has lhs => (isa => 'Op', is => 'ro', required => 1);
    has rhs => (isa => 'Op', is => 'ro', required => 1);
    has readonly => (isa => 'Bool', is => 'ro', required => 1);
    sub zyg { $_[0]->lhs, $_[0]->rhs }

    sub code {
        my ($self, $body) = @_;
        CgOp::prog(
            CgOp::bind($self->readonly, $self->lhs->code($body),
                $self->rhs->code($body)),
            CgOp::null('Variable'));
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

{
    package Op::Lexical;
    use Moose;
    extends 'Op';

    has name => (isa => 'Str', is => 'ro', required => 1);
    has state_decl => (isa => 'Bool', is => 'ro', default => 0);

    has declaring => (isa => 'Bool', is => 'ro');
    has list => (isa => 'Bool', is => 'ro');

    sub local_decls {
        my ($self) = @_;
        $self->declaring ?
            (Decl::SimpleVar->new(slot => $self->name, list => $self->list)) :
            ();
    }

    sub paren {
        Op::Lexical->new(name => shift()->name);
    }

    sub code {
        my ($self, $body) = @_;
        CgOp::scopedlex($self->name);
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

1;
