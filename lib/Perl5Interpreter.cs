using Niecza;
using System.Runtime.InteropServices;
using System;
using Niecza.Serialization;

public class Perl5Interpreter : IForeignInterpreter {
    [DllImport("obj/p5embed.so", EntryPoint="p5embed_initialize")]
    public static extern void Initialize();
  
    [DllImport("obj/p5embed.so", EntryPoint="p5embed_dispose")]
    public static extern void Dispose();
  
    [DllImport("obj/p5embed.so", EntryPoint="p5embed_eval")]
    public static extern IntPtr EvalPerl5(string code);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvIV")]
    public static extern int SvIV(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvPV_nolen")]
    public static extern string SvPV_nolen(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvPVutf8_nolen")]
    public static extern IntPtr SvPVutf8_nolen(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvPVutf8_length")]
    public static extern int SvPVutf8_length(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvNV")]
    public static extern double SvNV(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvIOKp")]
    public static extern int SvIOKp(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvNOKp")]
    public static extern int SvNOKp(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvPOKp")]
    public static extern int SvPOKp(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvOK")]
    public static extern int SvOK(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_newSVpvn")]
    public static extern IntPtr newSVpvn(IntPtr s,int length);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_SvUTF8_on")]
    public static extern void SvUTF8_on(IntPtr sv);

    [DllImport("obj/p5embed.so", EntryPoint="p5embed_subcall")]
    public static extern IntPtr SubCall(
        int context,
        IntPtr[] arguments,
        int argument_n
    );

    // We can't use the standard char* conversion because some strings can contain nulls
    public static string UnmarshalString(IntPtr sv) {
        int len = SvPVutf8_length(sv);
        byte[] target = new byte[len];
        IntPtr data = SvPVutf8_nolen(sv);
        Marshal.Copy(data, target, 0, len);
        return System.Text.Encoding.UTF8.GetString(target);
    }

    public static Variable SVToVariable(IntPtr sv) {
        if (sv == IntPtr.Zero) {
            //TODO: check - cargo culted
            return Kernel.NilP.mo.typeVar;
        }
        if (SvOK(sv) == 0) {
            return Kernel.NilP.mo.typeVar;
        }

        if (SvIOKp(sv) != 0) {
            return Builtins.MakeInt(SvIV(sv));
        } else if (SvNOKp(sv) != 0) {
            return Builtins.MakeFloat(SvNV(sv));
        } else if (SvPOKp(sv) != 0) {
            string s = UnmarshalString(sv); //SvPV_nolen(sv);
            return Kernel.BoxAnyMO(s, Kernel.StrMO);
        } else {
            return new SVVariable(sv);
        }
    }
  
    public Perl5Interpreter() {
        Initialize();
    }
    ~Perl5Interpreter() {
        Dispose();
    }
    public Variable Eval(string code) {
        IntPtr sv = EvalPerl5(code);
        return SVToVariable(sv);
    }
}

public class SVVariable : Variable {
    public IntPtr sv;
    public SVVariable(IntPtr _sv) {
        sv = _sv;
    }
    public override P6any Fetch() {
        return new SVany(sv);
    }
    public override void Store(P6any v) {
    }
    public override Variable GetVar() {
            return Kernel.BoxAnyMO<Variable>(this, Kernel.ScalarMO);

    }
    public override void Freeze(FreezeBuffer fb) {
            throw new NieczaException("Freezing perl5 SV* NYI.");
    }
}
public class SVany : P6any {
        [DllImport("obj/p5embed.so", EntryPoint="p5method_call")]
        public static extern IntPtr MethodCall(
            string name,
            IntPtr[] arguments,
            int argument_n
        );

        public override void Freeze(FreezeBuffer fb) {
                throw new NieczaException("Freezing perl5 SV* NYI.");
        }

        
        // We can't use the standard char* conversion because some strings can contain nulls
        public static IntPtr MarshalString(string s) {
            byte[] array = System.Text.Encoding.UTF8.GetBytes(s);
            int size = Marshal.SizeOf(typeof(byte)) * (array.Length + 1);

            IntPtr ptr = Marshal.AllocHGlobal(size);

            /* This is a hack not to crash on mono!!! */
            //allocated.Add(ptr, null);

            Marshal.Copy(array, 0, ptr, array.Length);
            Marshal.WriteByte(ptr, array.Length, 0);

            IntPtr sv = Perl5Interpreter.newSVpvn(ptr,array.Length);
            Perl5Interpreter.SvUTF8_on(sv);
            Marshal.FreeHGlobal(ptr);
            return sv;
        }



        public static IntPtr VariableToSV(Variable var) {
            P6any obj = var.Fetch();
            if (obj is SVany) {
                return ((SVany)obj).sv;
            } else if (obj.Does(Kernel.StrMO)) {
                string s = Kernel.UnboxAny<string>(obj);
                return MarshalString(s);
            } else {
                throw new NieczaException("can't convert argument to p5 type");
            }
        }

        static int Context(Variable var) {
            P6any obj = var.Fetch();
            string s = Kernel.UnboxAny<string>(obj);
            if (s == "list") {
                return 0;
            } else if (s == "scalar") {
                return 1;
            } else if (s == "void") {
                return 2;
            } else {
                throw new NieczaException("unknown p5 context type: "+s);
            }
        }

        static IntPtr[] MarshalPositionals(Variable[] pos) {
                IntPtr[] args = new IntPtr[pos.Length];
                for (int i=0;i<pos.Length;i++) {
                    args[i] = VariableToSV(pos[i]);
                }
                return args;
        }

        public IntPtr sv;
        public override Frame InvokeMethod(Frame caller, string name,
                Variable[] pos, VarHash named) {

                if (name == "postcircumfix:<( )>") {
                    int context = 1;
                    if (named != null && named["context"] != null) {
                        context = Context(named["context"]);
                    }
                    IntPtr[] args = MarshalPositionals(pos);
                    IntPtr ret = Perl5Interpreter.SubCall(context,args,args.Length);

            
                    caller.resultSlot = Perl5Interpreter.SVToVariable(ret);
                    return caller;
                } else {
                    IntPtr[] args = MarshalPositionals(pos);
                    IntPtr ret = MethodCall(name,args,args.Length);
                    caller.resultSlot = Perl5Interpreter.SVToVariable(ret);
                }

                return caller;
        }

        public override string ReprName() { return "P6opaque"; }

        public SVany(IntPtr _sv) {
            mo = Kernel.AnyMO;
            sv = _sv;
        }
}

