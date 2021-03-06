unit tcclib;

{$mode objfpc}{$H+}


interface

uses
  windows, Classes, SysUtils, syncobjs{$ifndef standalonetest}, SymbolListHandler{$endif};


type
  TTCCTarget=(x86_64,i386);
  PTCCState=pointer;
  {$ifdef standalonetest}
  TSymbolListHandler=pointer;
  {$endif}


  TTCC=class(TObject)
  private
    cs: TCriticalSection; static;
    working: boolean;

    new: function():PTCCState; cdecl;
    parse_args: function(s:PTCCState; pargc: pinteger; pargv: pchar; optind: integer):integer; cdecl;//  //(TCCState *s, int *pargc, char ***pargv, int optind)
    set_options: procedure(s: PTCCState; str: pchar); cdecl;
    set_lib_path: procedure(s: PTCCState; path: pchar); cdecl;
    add_include_path: procedure(s: PTCCState; path: pchar); cdecl;
    set_error_func:procedure(s: PTCCState; error_opaque: pointer; functionToCall: pointer); cdecl;
    set_symbol_lookup_func:procedure(s:PTCCState; userdata: pointer; functionToCall: pointer); cdecl;
    set_binary_writer_func:procedure(s:PTCCState; param: pointer; functionToCall: pointer); cdecl;

    set_output_type:function(s: PTCCState; output_type: integer): integer; cdecl;
    compile_string:function(s: PTCCState; buf: pchar): integer; cdecl;


    get_symbol:function(s: PTCCState; name: pchar):pointer; cdecl;
    get_symbols:function(s: PTCCState; userdata: pointer; functionToCall: pointer):pointer; cdecl;

    delete:procedure(s: PTCCState); cdecl;
    add_file:function(s: PTCCState; filename: pchar): integer; cdecl;
    output_file:function(s: PTCCState; filename: pchar): integer; cdecl;

    procedure setupCompileEnvironment(s: PTCCState; address: ptruint; output: tstream; textlog: tstrings; targetself: boolean=false);
  public
    function testcompileScript(script: string; var bytesize: integer; referencedSymbols: TStrings; textlog: tstrings=nil; targetself: boolean=false): boolean;
    function compileScript(script: string; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; secondaryLookupList: tstrings=nil; targetself: boolean=false): boolean;
    function compileScripts(scripts: tstrings; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; targetself: boolean=false): boolean;
    function compileProject(files: tstrings; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; targetself: boolean=false): boolean;

    constructor create(target: TTCCTarget);
  end;


  function tcc: TTCC;
  function tccself: TTCC;

implementation

uses forms,dialogs{$ifndef standalonetest}, symbolhandler, ProcessHandlerUnit{$endif};
const
  TCC_RELOCATE_AUTO=pointer(1); //relocate
  TCC_OUTPUT_MEMORY  = 1; { output will be run in memory (default) }
  TCC_OUTPUT_EXE     = 2; { executable file }
  TCC_OUTPUT_DLL     = 3; { dynamic library }
  TCC_OUTPUT_OBJ     = 4; { object file }
  TCC_OUTPUT_PREPROCESS = 5; { only preprocess (used internally) }



var
  initDone: boolean;
  tcc32: TTCC;
  {$ifdef cpu64}
  tcc64: TTCC;
  {$endif}

function tcc: TTCC;
begin
  {$ifndef standalonetest}
    {$ifdef cpu64}
    if processhandler.is64bit then
      result:=tcc64
    else
    {$endif}
      result:=tcc32;
  {$else}
    result:=tcc64;
  {$endif}
end;

function tccself: TTCC;
begin
  {$ifdef cpu64}
  result:=tcc64;
  {$else}
  result:=tcc32;
  {$endif}
end;

constructor TTCC.create(target: TTCCTarget);
var module: HModule;
begin
  if initDone=true then raise exception.create('Do not create more compilers after init');
  if cs=nil then
    cs:=TCriticalSection.create;


  {$ifdef cpu32}
  module:=LoadLibrary({$ifdef standalonetest}'D:\git\cheat-engine\Cheat Engine\bin\'+{$endif}'tcc32-32.dll'); //generates 32-bit code
  {$else}
  if target=x86_64 then
    module:=loadlibrary({$ifdef standalonetest}'D:\git\cheat-engine\Cheat Engine\bin\'+{$endif}'tcc64-64.dll')
  else
    module:=loadlibrary({$ifdef standalonetest}'D:\git\cheat-engine\Cheat Engine\bin\'+{$endif}'tcc64-32.dll'); //generates 32-bit code
  {$endif}


  pointer(new):=GetProcAddress(module,'tcc_new');

  pointer(parse_args):=GetProcAddress(module,'tcc_parse_args');
  pointer(set_options):=GetProcAddress(module,'tcc_set_options');
  pointer(set_lib_path):=GetProcAddress(module,'tcc_set_lib_path');
  pointer(add_include_path):=GetProcAddress(module,'tcc_add_include_path');
  pointer(set_error_func):=GetProcAddress(module,'tcc_set_error_func');

  pointer(set_output_type):=GetProcAddress(module,'tcc_set_output_type');
  pointer(set_symbol_lookup_func):=GetProcAddress(module,'tcc_set_symbol_lookup_func');
  pointer(set_binary_writer_func):=GetProcAddress(module,'tcc_set_binary_writer_func');
  pointer(compile_string):=GetProcAddress(module,'tcc_compile_string');

  pointer(add_file):=GetProcAddress(module,'tcc_add_file');
  pointer(output_file):=GetProcAddress(module,'tcc_output_file');

  pointer(get_symbol):=GetProcAddress(module,'tcc_get_symbol');
  pointer(get_symbols):=GetProcAddress(module,'tcc_get_symbols');
  pointer(delete):=GetProcAddress(module,'tcc_delete');

  working:=(module<>0) and
           assigned(new) and
           assigned(set_options) and
           assigned(add_include_path) and
           assigned(compile_string) and
           assigned(output_file) and
           assigned(delete);
end;

procedure ErrorLogger(opaque: pointer; msg: pchar); cdecl;
begin
  tstrings(opaque).Add(msg);
end;

function symbolLookupFunctionTestCompile( log: tstrings; name: pchar): pointer; cdecl;
begin
  result:=pointer($00400000);

  if log<>nil then
    log.add(name);
end;

function symbolLookupFunction(secondaryLookup: tstrings; name: pchar): pointer; cdecl;
var
  error: boolean;
  i: integer;
begin
  {$ifdef standalonetest}
  result:=pointer($1234);
  {$else}

  if secondaryLookup<>nil then
  begin
    i:=secondaryLookup.IndexOf(name);
    if i<>-1 then
      exit(secondaryLookup.Objects[i]);
  end;

  result:=pointer(symhandler.GetAddressFromName(name,true,error));
  {$endif}
end;

function symbolLookupFunctionSelf(secondaryLookup: tstrings; name: pchar): pointer; cdecl;
var
  error: boolean;
  i: integer;
begin


  if secondaryLookup<>nil then
  begin
    i:=secondaryLookup.IndexOf(name);
    if i<>-1 then
      exit(secondaryLookup.Objects[i]);
  end;

  result:=pointer(selfsymhandler.GetAddressFromName(name,true,error));

end;

procedure Writer(output: TStream; data: pointer; size: integer);  cdecl;
begin
  output.Write(data^,size);
end;

procedure symbolCallback(sl: TSymbolListHandler; address: qword; name: pchar); cdecl;
begin
  {$ifndef standalonetest}
  if sl<>nil then sl.AddSymbol('',name,address,1);
  {$else}
  showmessage(inttohex(address,8)+' - '+name);
  {$endif}


end;

procedure ttcc.setupCompileEnvironment(s: PTCCState; address: ptruint; output: tstream; textlog: tstrings; targetself: boolean=false);
var
  str: string;
  args: pchar;

  p1: pointer;
  count: integer;

  sarr: array of pchar;
  i: integer;
begin
  add_include_path(s,'include');
  add_include_path(s,'include\winapi');
  add_include_path(s,'include\sys');
  add_include_path(s,pchar(ExtractFilePath(application.exename)+'include'));
  add_include_path(s,pchar(ExtractFilePath(application.exename)+'include\winapi'));
  add_include_path(s,pchar(ExtractFilePath(application.exename)+'include\sys'));

  if address=0 then
    set_options(s,pchar('-nostdlib -static -Wl,-section-alignment=4 -Wl,-oformat=binary -skip_unwind '))
  else
    set_options(s,pchar('-nostdlib -static -Wl,-image-base=0x'+inttohex(address,1)+' -Wl,-section-alignment=4 -Wl,-oformat=binary -skip_unwind'));

  if textlog<>nil then set_error_func(s,textlog,@ErrorLogger);

  if targetself then
    set_symbol_lookup_func(s,nil,@symbolLookupFunctionSelf)
  else
    set_symbol_lookup_func(s,nil,@symbolLookupFunction);

  set_binary_writer_func(s,output,@Writer);
end;

function ttcc.testcompileScript(script: string; var bytesize: integer; referencedSymbols: TStrings; textlog: tstrings=nil; targetself: boolean=false): boolean;
var s: PTCCState;
  r: pointer;
  ms: Tmemorystream;
begin
  result:=false;
  if not working then
  begin
    if textlog<>nil then textlog.add('Incorrect tcc library');
    exit(false);
  end;


  cs.enter;
  s:=new();
  ms:=tmemorystream.create;
  try

    setupCompileEnvironment(s,$00400000, ms, textlog);
    set_symbol_lookup_func(s,referencedSymbols, @symbolLookupFunctionTestCompile);

    if compile_string(s,pchar(script))=-1 then exit(false);
    if output_file(s,nil)=-1 then exit(false);

    bytesize:=ms.Size;

    result:=true;
  finally
    delete(s);
    cs.leave;

    if ms<>nil then
      freeandnil(ms);
  end;
end;

function ttcc.compileScript(script: string; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; secondaryLookupList: tstrings=nil; targetself: boolean=false): boolean;
var s: PTCCState;
  r: pointer;
begin
  result:=false;
  if not working then
  begin
    if textlog<>nil then textlog.add('Incorrect tcc library');
    exit(false);
  end;


  cs.enter;
  s:=new();
  try
    setupCompileEnvironment(s,address, output, textlog, targetself);
    if secondaryLookupList<>nil then   //AA scripts can provide some extra addresses
      set_symbol_lookup_func(s,secondaryLookupList, @symbolLookupFunction);

    if compile_string(s,pchar(script))=-1 then exit(false);
    if output_file(s,nil)=-1 then exit(false);

    //still alive, get the symbols
    if symbollist<>nil then
      get_symbols(s, symbollist, @symbolCallback);

    result:=true;
  finally
    delete(s);
    cs.leave;
  end;
end;

function ttcc.compileScripts(scripts: tstrings; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; targetself: boolean=false):boolean;
var
  s: PTCCState;
  i: integer;
begin
  result:=false;
  if not working then
  begin
    if textlog<>nil then textlog.add('Incorrect tcc library');
    exit(false);
  end;

  cs.enter;
  s:=new();
  try
    setupCompileEnvironment(s,address, output, textlog, targetself);
    for i:=0 to scripts.count-1 do
      if compile_string(s,pchar(scripts[i]))=-1 then exit(false);

    if output_file(s,nil)=-1 then exit(false);

    //still alive, get the symbols
    if symbollist<>nil then
      get_symbols(s, symbollist, @symbolCallback);

    result:=true;
  finally
    delete(s);
    cs.leave;
  end;

end;


function ttcc.compileProject(files: tstrings; address: ptruint; output: tstream; symbollist: TSymbolListHandler; textlog: tstrings=nil; targetself: boolean=false):boolean;
var
  s: PTCCState;
  i: integer;
begin
  result:=false;
  if not working then
  begin
    if textlog<>nil then textlog.add('Incorrect tcc library');
    exit(false);
  end;

  cs.enter;
  s:=new();
  try
    setupCompileEnvironment(s,address, output, textlog, targetself);
    for i:=0 to files.count-1 do
      if add_file(s, pchar(files[i]))=-1 then exit(false);

    if output_file(s,nil)=-1 then exit(false);

    //still alive, get the symbols
    if symbollist<>nil then
      get_symbols(s, symbollist, @symbolCallback);

    result:=true;
  finally
    delete(s);
    cs.leave;
  end;

end;


function initTCCLib: boolean;
begin
  {$ifndef standalonetest}
  tcc32:=ttcc.create(i386);
  {$endif}
  {$ifdef cpu64}
  tcc64:=ttcc.create(x86_64);
  {$endif}
  initDone:=true;
end;

initialization
  initTCCLib;

end.

