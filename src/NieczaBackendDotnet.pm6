class NieczaBackendDotnet;

use NAMOutput;
use JSYNC;
use NieczaPassSimplifier;
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

class Unit { ... }
class StaticSub { ... }
class Type { ... }

method new(*%_) {
    Q:CgOp { (rnull (rawscall Niecza.Downcaller,CompilerBlob.InitSlave {&upcalled} {Unit} {StaticSub} {Type})) };
    nextsame;
}

sub downcall(*@args) {
    Q:CgOp { (rawscall Niecza.Downcaller,CompilerBlob.DownCall {@args}) }
}

method accept($unitname, $unit, :$main, :$run, :$evalmode, :$repl) { #OK not used
    downcall("safemode") if $.safemode;
    if $run {
        downcall("setnames", $*PROGRAM_NAME // '???',
            $*orig_file // '(eval)') unless $repl;
        downcall("run_unit", $unit, ?$evalmode, @$!run_args);
        if $repl {
            downcall("replrun");
        }
        $*repl_outer = $unit.get_mainline if $repl;
        return;
    }
    downcall("save_unit", $unit, ?$main);
    $*repl_outer = $unit.get_mainline if $repl;
}

method post_save($name, :$main) {
    my $fname = $name.split('::').join('.');
    downcall("post_save",
        $.obj_dir, $fname ~ ".nam", $fname ~ ($main ?? ".exe" !! ".dll"),
        $main ?? "1" !! "0");
}

class StaticSub {
    method lex_names() { downcall("lex_names", self) }
    method lookup_lex($name, $file?, $line?) {
        downcall("sub_lookup_lex", self, $name, $file, $line//0);
    }
    method set_outervar($v) { downcall("sub_set_outervar", self, $v) }
    method set_class($n)    { downcall("sub_set_class", self, ~$n) }
    method set_name($v)     { downcall("sub_set_name", self, ~$v) }
    method set_methodof($m) { downcall("sub_set_methodof", self, $m) }
    method set_in_class($m) { downcall("sub_set_in_class", self, $m) }
    method set_cur_pkg($m)  { downcall("sub_set_cur_pkg", self, $m) }
    method set_body_of($m)  { downcall("sub_set_body_of", self, $m) }

    method name()     { downcall("sub_name", self) }
    method outer()    { downcall("sub_outer", self) }
    method class()    { downcall("sub_class", self) }
    method run_once() { downcall("sub_run_once", self) }
    method cur_pkg()  { downcall("sub_cur_pkg", self) }
    method in_class() { downcall("sub_in_class", self) }
    method body_of()  { downcall("sub_body_of", self) }
    method outervar() { downcall("sub_outervar", self) }
    method methodof() { downcall("sub_methodof", self) }

    method unused_lexicals() { downcall("unused_lexicals", self) }
    method parameterize_topic() { downcall("sub_parameterize_topic", self) }
    method unit() { downcall("sub_get_unit", self) }
    method to_unit() { downcall("sub_to_unit", self) }
    method is($o) { downcall("equal_handles", self, $o) }
    method is_routine() { downcall("sub_is_routine", self) }
    method has_lexical($name) { downcall("sub_has_lexical", self, $name) }
    method lexical_used($name) { downcall("sub_lexical_used", self, $name) }

    method set_signature($sig) {
        my @args;
        if !$sig {
            downcall("sub_no_signature", self);
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
        downcall("set_signature", self, @args);
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
        self._addlex_result(downcall("add_my_name", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1), $typeconstraint,
            ($noinit ?? 1 !! 0) + ($roinit ?? 2 !! 0) + ($defouter ?? 4 !! 0) +
            ($list ?? 8 !! 0) + ($hash ?? 16 !! 0)));
    }
    method add_hint($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_hint", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1)));
    }
    method add_label($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_label", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1)));
    }
    method add_dispatcher($name, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_dispatcher", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1)));
    }
    method add_common_name($name, $pkg, $pname, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_common_name", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1), $pkg, ~$pname));
    }
    method add_state_name($name, $backing, :$file, :$line, :$pos, :$noinit,
            :$defouter, :$roinit, :$list, :$hash, :$typeconstraint) {
        self._addlex_result(downcall("add_state_name", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1), $typeconstraint,
            ($noinit ?? 1 !! 0) + ($roinit ?? 2 !! 0) + ($defouter ?? 4 !! 0) +
            ($list ?? 8 !! 0) + ($hash ?? 16 !! 0),
            $backing));
    }
    method add_my_stash($name, $pkg, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_my_stash", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1), $pkg));
    }
    method add_my_sub($name, $body, :$file, :$line, :$pos) {
        self._addlex_result(downcall("add_my_sub", self, ~$name,
            ~($file//''), +($line//0), +($pos// -1), $body));
    }

    method finish($ops) { 
        $ops := NieczaPassSimplifier.invoke_incr(self, $ops);
        downcall("sub_finish", self, to-json($ops.cgop(self)));
    }
}

class Type {
    method is_package() { downcall("type_is_package", self) }
    method closed() { downcall("type_closed", self) }
    method close() { downcall("type_close", self) }
    method kind() { downcall("type_kind", self) }
    method name() { downcall("type_name", self) }
}

class Unit {
    method name() { downcall("unit_get_name", self) }
    method stubbed_stashes() { downcall("unit_stubbed_stashes", self) }
    method anon_stash() { downcall("unit_anon_stash", self) }
    method stub_stash($pos, $type) { downcall("unit_stub_stash", $pos, $type) }
    method set_current() { downcall("set_current_unit", self) }
    method set_mainline($sub) { downcall("set_mainline", $sub) }
    method abs_pkg(*@names, :$auto) { downcall("rel_pkg", ?$auto, Any, @names) }
    method rel_pkg($pkg, *@names, :$auto) {
        downcall("rel_pkg", ?$auto, $pkg, @names)
    }
    method get($pkg, $name) {
        downcall("unit_get", $pkg, $name);
    }
    method bind($pkg, $name, $item, :$file, :$line, :$pos) { #OK
        downcall("unit_bind", ~$pkg, ~$name, $item, ~($file // '???'),
            $line // 0);
    }

    method create_type(:$name, :$class, :$who) {
        downcall("type_create", self, ~$name, ~$class, ~$who);
    }
    method create_sub(:$name, :$class, :$outer, :$cur_pkg, :$in_class,
            :$run_once) {
        downcall("create_sub", ~($name // 'ANON'), $outer, ~($class // 'Sub'),
            $cur_pkg, $in_class, ?$run_once)
    }
}

method create_unit($name, $filename, $modtime, $main, $run) {
    downcall("new_unit", ~$name, ~$filename, ~$modtime,
            ~$!obj_dir, ?$main, ?$run);
}
