class NieczaBackendDotnet;

use NAMOutput;
use Metamodel;

has $.safemode = False;
has $.obj_dir;
has $.run_args = [];

# The purpose of the backend is twofold.  It must be able to accept
# and process units; and it must be able to retrieve processed units
# at a later time.

# Return Metamodel::Unit, undefined if unit not available.  The caller
# will check tdeps, load them if needed, and maybe even discard the
# returned unit.
method get_unit($name) {
    my $file = ($name.split('::').join('.') ~ ".nam").IO\
        .relative($.obj_dir);
    $file.e ?? NAMOutput.load($file.slurp) !! ::Metamodel::Unit;
}

# Save a unit.  If $main is true, it is being considered as a main
# module; if $run, it should be auto-run.  Main modules do not need
# to be retrievable.
method save_unit($name, $unit) {
    my $file = ($name.split('::').join('.') ~ ".nam").IO\
        .relative($.obj_dir);
    $file.spew(NAMOutput.run($unit));
}

sub upcalled(@strings) {
    given @strings[0] {
        when "eval" {
            my $*IN_EVAL = True;
            # XXX NieczaException is eaten by boundary
            try {
                $*compiler.compile_string(@strings[1], True, :evalmode,
                    :outer([@strings[2], +@strings[3]]));
                return "";
            }
            return $!;
        }
        say "upcall: @strings.join('|')";
        "ERROR";
    }
}

method new(*%_) {
    Q:CgOp { (rnull (rawscall Niecza.Downcaller,CompilerBlob.InitSlave {&upcalled})) };
    nextsame;
}

sub downcall(*@args) {
    Q:CgOp { (rawscall Niecza.Downcaller,CompilerBlob.DownCall {@args}) }
}

method accept($unitname, $ast is rw, :$main, :$run, :$evalmode, :$repl) {
    downcall("safemode") if $.safemode;
    if $run {
        downcall("setnames", $*PROGRAM_NAME // '???',
            $*orig_file // '(eval)') unless $repl;
        my $nam = NAMOutput.run($ast);
        $ast.clear_optrees;
        my ($exn) = downcall(($evalmode ?? "evalnam" !! "runnam"), $.obj_dir, $nam, @$.run_args);
        die $exn if $exn;
        if $repl {
            my ($exn) = downcall("replrun");
            die $exn if $exn;
        }
        $*repl_outer = $ast.mainline.xref if $repl;
        $ast = Any;
        return;
    }
    self.save_unit($unitname, $ast);
    $ast.clear_optrees;
    self.post_save($unitname, :$main);
    $*repl_outer = $ast.mainline.xref if $repl;
    $ast = Any;
}

method post_save($name, :$main) {
    my $fname = $name.split('::').join('.');
    downcall("post_save",
        $.obj_dir, $fname ~ ".nam", $fname ~ ($main ?? ".exe" !! ".dll"),
        $main ?? "1" !! "0");
}

class Unit { ... }
class StaticSub { ... }
class Type { ... }

class StaticSub {
    has $.peer;
    method lex_names() { downcall("lex_names", $!peer) }
    method unit() { Unit.new(peer => downcall("sub_get_unit", $!peer)) }
    method set_signature($sig) {
        my @args;
        if !$sig {
            downcall("sub_no_signature", $!peer);
            return;
        }
        for @( $sig.params ) {
            my $flags = 0;
            # keep synced with SIG_F_ constants
            if .rwtrans       { $flags +|= 8 }
            if .rw            { $flags +|= 2 }

            if .hash || .list { $flags +|= 16 }
            if .defouter      { $flags +|= 4096 }
            if .invocant      { $flags +|= 8192 }
            if .multi_ignored { $flags +|= 16384 }
            if .is_copy       { $flags +|= 32768 }
            if .list          { $flags +|= 65536 }
            if .hash          { $flags +|= 131072 }
            if .tclass        { $flags +|= 1 }
            if .mdefault      { $flags +|= 32 }
            if .optional      { $flags +|= 64 }
            if .positional    { $flags +|= 128 }
            if .slurpy        { $flags +|= (.hash ?? 512 !! 256) }
            if .slurpycap     { $flags +|= 1024 }
            if .full_parcel   { $flags +|= 2048 }

            push @args, $flags, .name, .slot, @( .names ), Str,
                .mdefault, .tclass;
        }
        downcall("set_signature", $!peer, @args);
    }

    # TODO: prevent foo; sub foo { } from warning undefined
    # needs a %*MYSTERY check when evaluating unused variables
    method _addlex_result(*@args) {
        given @args[0] {
            when 'collision' {
                my ($ , $slot, $nf,$nl,$of,$ol) = @args;
                my $l = Metamodel.locstr($of, $ol, $nf, $nl);
                if $slot ~~ /^\w/ {
                    die "Illegal redeclaration of symbol '$slot'$l";
                } elsif $slot ~~ /^\&/ {
                    die "Illegal redeclaration of routine '$slot.substr(1)'$l";
                } else {
                    $*worry.("Useless redeclaration of variable $slot$l");
                }
            }
            when 'already-bound' {
                my ($ , $slot, $count, $line, $nf,$nl,$of,$ol) = @args;
                my $truename = $slot;
                $truename ~~ s/<?before \w>/OUTER::/ for ^$count;
                die "Lexical symbol '$slot' is already bound to an outer symbol{Metamodel.locstr($of, $ol, $nf, $nl)};\n  the implicit outer binding at line $line must be rewritten as $truename\n  before you can unambiguously declare a new '$slot' in this scope";
            }
        }
    }

    method add_my_name($name, :$file, :$line, :$pos, :$noinit, :$defouter,
            :$roinit, :$list, :$hash, :$typeconstraint) {
        self._addlex_result(downcall("add_my_name", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0),
            $typeconstraint && $typeconstraint.peer,
            ($noinit ?? 1 !! 0) + ($roinit ?? 2 !! 0) + ($defouter ?? 4 !! 0) +
            ($list ?? 8 !! 0) + ($hash ?? 16 !! 0)));
    }
    method add_hint($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_hint", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0)));
    }
    method add_label($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_label", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0)));
    }
    method add_dispatcher($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_dispatcher", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0)));
    }
    method add_common_name($name, $pkg, $pname, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_common_name", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0), $pkg.peer, ~$pname));
    }
    method add_state_name($name, $backing, :$file, :$line, :$pos, :$noinit,
            :$defouter, :$roinit, :$list, :$hash, :$typeconstraint) {
        self._addlex_result(downcall("add_state_name", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0),
            $typeconstraint && $typeconstraint.peer,
            ($noinit ?? 1 !! 0) + ($roinit ?? 2 !! 0) + ($defouter ?? 4 !! 0) +
            ($list ?? 8 !! 0) + ($hash ?? 16 !! 0),
            $backing));
    }
    method add_my_stash($name, $pkg, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_my_stash", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0), $pkg.peer));
    }
    method add_my_sub($name, $body, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_my_stash", $!peer, ~$name,
            ~($file//''), +($line//0), +($pos//0), $body.peer));
    }
}

class Type {
    has $.peer;
}

class Unit {
    has $.peer;
    method name() { downcall("unit_get_name", $!peer) }
    method set_current() { downcall("set_current_unit", $!peer) }
    method set_mainline($sub) { downcall("set_mainline", $sub.peer) }
    method abs_pkg(*@names, :$auto) {
        Type.new(peer => downcall("rel_pkg", ?$auto, Any, @names))
    }
    method rel_pkg($pkg, *@names, :$auto) {
        Type.new(peer => downcall("rel_pkg", ?$auto, $pkg.peer, @names))
    }
    method get($pkg, $name) {
        my ($p,$k) = downcall("get_name", $pkg, $name);
        $k ?? Type.new(peer => $p) !! StaticSub.new(peer => $p)
    }
    method create_sub(:$name, :$class, :$outer, :$cur_pkg, :$run_once) {
        StaticSub.new(peer => downcall("create_sub", ~($name // 'ANON'),
            $outer && $outer.peer, ~($class // 'Sub'), $cur_pkg.peer,
            ?$run_once))
    }
}

method create_unit($name, $filename, $modtime) {
    Unit.new(peer => downcall("new_unit", ~$name, ~$filename, ~$modtime));
}
