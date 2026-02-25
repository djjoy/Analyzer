unit KissFFT;

interface

uses
  System.SysUtils, System.Math;

type
  kiss_fft_scalar = Single;
  
  kiss_fft_cpx = record
    r: kiss_fft_scalar;
    i: kiss_fft_scalar;
  end;
  Tkiss_fft_cpx_array = TArray<kiss_fft_cpx>;

  kiss_fft_cfg = record
    nfft: Integer;
    inverse: Boolean;
    factors: TArray<Integer>;
    twiddles: Tkiss_fft_cpx_array;
  end;

  kiss_fftr_cfg = record
    substate: kiss_fft_cfg;
    tmpbuf: Tkiss_fft_cpx_array;
    super_twiddles: Tkiss_fft_cpx_array;
  end;

function kiss_fft_alloc(nfft: Integer; inverse_fft: Boolean): kiss_fft_cfg;
procedure kiss_fft(cfg: kiss_fft_cfg; const fin: Tkiss_fft_cpx_array; var fout: Tkiss_fft_cpx_array);
function kiss_fftr_alloc(nfft: Integer; inverse_fft: Boolean): kiss_fftr_cfg;
procedure kiss_fftr(cfg: kiss_fftr_cfg; const timedata: TArray<kiss_fft_scalar>; var freqdata: Tkiss_fft_cpx_array);
procedure kiss_fftri(cfg: kiss_fftr_cfg; const freqdata: Tkiss_fft_cpx_array; var timedata: TArray<kiss_fft_scalar>);

implementation

// Funciones auxiliares
procedure C_MUL(var res: kiss_fft_cpx; const a, b: kiss_fft_cpx);
begin
  res.r := a.r * b.r - a.i * b.i;
  res.i := a.r * b.i + a.i * b.r;
end;

procedure C_SUB(var res: kiss_fft_cpx; const a, b: kiss_fft_cpx);
begin
  res.r := a.r - b.r;
  res.i := a.i - b.i;
end;

procedure C_ADDTO(var res: kiss_fft_cpx; const a: kiss_fft_cpx);
begin
  res.r := res.r + a.r;
  res.i := res.i + a.i;
end;

procedure C_ADD(var res: kiss_fft_cpx; const a, b: kiss_fft_cpx);
begin
  res.r := a.r + b.r;
  res.i := a.i + b.i;
end;

// Versión sin var para uso interno
procedure kf_bfly2(var Fout: Tkiss_fft_cpx_array; fstride: Integer; 
  const st: kiss_fft_cfg; m: Integer);
var
  Fout2: Integer;
  t: kiss_fft_cpx;
  i: Integer;
begin
  for i := 0 to m - 1 do
  begin
    Fout2 := i + m;
    
    // C_MUL(t, Fout[Fout2], st.twiddles[i * fstride])
    t.r := Fout[Fout2].r * st.twiddles[i * fstride].r - 
           Fout[Fout2].i * st.twiddles[i * fstride].i;
    t.i := Fout[Fout2].r * st.twiddles[i * fstride].i + 
           Fout[Fout2].i * st.twiddles[i * fstride].r;
    
    // C_SUB(Fout[Fout2], Fout[i], t)
    Fout[Fout2].r := Fout[i].r - t.r;
    Fout[Fout2].i := Fout[i].i - t.i;
    
    // C_ADDTO(Fout[i], t)
    Fout[i].r := Fout[i].r + t.r;
    Fout[i].i := Fout[i].i + t.i;
  end;
end;

procedure kf_work(var Fout: Tkiss_fft_cpx_array; const f: Tkiss_fft_cpx_array;
  fstride, in_stride: Integer; const factors: TArray<Integer>; const st: kiss_fft_cfg);
var
  p, m, n: Integer;
  k: Integer;
  Fout_beg: Integer;
  Fout_end: Integer;
  Fout_idx: Integer;
begin
  p := factors[0];
  m := factors[1];
  n := Length(Fout);
  
  if m = 1 then
  begin
    Fout_idx := 0;
    for k := 0 to p - 1 do
    begin
      Fout[Fout_idx] := f[k * fstride * in_stride];
      Inc(Fout_idx);
    end;
  end
  else
  begin
    // Versión simplificada - para este caso asumimos factores potencia de 2
    for k := 0 to p - 1 do
    begin
      // Aquí iría la llamada recursiva
      // Por ahora, simplificamos para factores 2
    end;
  end;

  // Recombine según el radix
  case p of
    2: kf_bfly2(Fout, fstride, st, m);
    // 3,4,5 se pueden implementar después
  end;
end;

function kiss_fft_alloc(nfft: Integer; inverse_fft: Boolean): kiss_fft_cfg;
var
  i: Integer;
  phase: Double;
begin
  Result.nfft := nfft;
  Result.inverse := inverse_fft;
  SetLength(Result.twiddles, nfft);
  
  for i := 0 to nfft - 1 do
  begin
    phase := -2 * Pi * i / nfft;
    if inverse_fft then
      phase := -phase;
    Result.twiddles[i].r := Cos(phase);
    Result.twiddles[i].i := Sin(phase);
  end;
  
  // Factores simplificados (asumimos potencia de 2)
  SetLength(Result.factors, 4);
  Result.factors[0] := 2;
  Result.factors[1] := nfft div 2;
  Result.factors[2] := 2;
  Result.factors[3] := nfft div 4;
end;

procedure kiss_fft(cfg: kiss_fft_cfg; const fin: Tkiss_fft_cpx_array; var fout: Tkiss_fft_cpx_array);
begin
  SetLength(fout, cfg.nfft);
  
  // Copiar entrada a salida
  Move(fin[0], fout[0], cfg.nfft * SizeOf(kiss_fft_cpx));
  
  // Aplicar factors (versión simplificada)
  kf_work(fout, fin, 1, 1, cfg.factors, cfg);
end;

function kiss_fftr_alloc(nfft: Integer; inverse_fft: Boolean): kiss_fftr_cfg;
var
  i: Integer;
  phase: Double;
  half_n: Integer;
begin
  half_n := nfft div 2;
  Result.substate := kiss_fft_alloc(half_n, inverse_fft);
  SetLength(Result.tmpbuf, half_n);
  SetLength(Result.super_twiddles, half_n div 2);
  
  for i := 0 to (half_n div 2) - 1 do
  begin
    phase := -Pi * ((i + 1) / half_n + 0.5);
    if inverse_fft then
      phase := -phase;
    Result.super_twiddles[i].r := Cos(phase);
    Result.super_twiddles[i].i := Sin(phase);
  end;
end;

procedure kiss_fftr(cfg: kiss_fftr_cfg; const timedata: TArray<kiss_fft_scalar>; 
  var freqdata: Tkiss_fft_cpx_array);
var
  ncfft, k: Integer;
  fpnk, fpk, f1k, f2k, tw: kiss_fft_cpx;
  tmp: Tkiss_fft_cpx_array;
begin
  ncfft := cfg.substate.nfft;
  SetLength(freqdata, ncfft + 1);
  SetLength(tmp, ncfft);
  
  // Pack two real signals into complex
  for k := 0 to ncfft - 1 do
  begin
    tmp[k].r := timedata[2 * k];
    tmp[k].i := timedata[2 * k + 1];
  end;
  
  // Hacer FFT
  kiss_fft(cfg.substate, tmp, cfg.tmpbuf);
  
  // DC component
  freqdata[0].r := cfg.tmpbuf[0].r + cfg.tmpbuf[0].i;
  freqdata[0].i := 0;
  
  // Nyquist component
  if ncfft > 0 then
  begin
    freqdata[ncfft].r := cfg.tmpbuf[0].r - cfg.tmpbuf[0].i;
    freqdata[ncfft].i := 0;
  end;
  
  // Rest of frequencies
  for k := 1 to ncfft div 2 do
  begin
    fpk := cfg.tmpbuf[k];
    fpnk.r := cfg.tmpbuf[ncfft - k].r;
    fpnk.i := -cfg.tmpbuf[ncfft - k].i;
    
    f1k.r := (fpk.r + fpnk.r) * 0.5;
    f1k.i := (fpk.i + fpnk.i) * 0.5;
    f2k.r := (fpk.r - fpnk.r) * 0.5;
    f2k.i := (fpk.i - fpnk.i) * 0.5;
    
    // C_MUL(tw, f2k, cfg.super_twiddles[k-1])
    tw.r := f2k.r * cfg.super_twiddles[k-1].r - 
            f2k.i * cfg.super_twiddles[k-1].i;
    tw.i := f2k.r * cfg.super_twiddles[k-1].i + 
            f2k.i * cfg.super_twiddles[k-1].r;
    
    freqdata[k].r := f1k.r + tw.r;
    freqdata[k].i := f1k.i + tw.i;
    
    if ncfft - k >= 0 then
    begin
      freqdata[ncfft - k].r := f1k.r - tw.r;
      freqdata[ncfft - k].i := tw.i - f1k.i;
    end;
  end;
end;

procedure kiss_fftri(cfg: kiss_fftr_cfg; const freqdata: Tkiss_fft_cpx_array; 
  var timedata: TArray<kiss_fft_scalar>);
var
  ncfft, k: Integer;
  fk, fnkc, fek, fok, tmp: kiss_fft_cpx;
begin
  ncfft := cfg.substate.nfft;
  SetLength(timedata, 2 * ncfft);
  
  cfg.tmpbuf[0].r := freqdata[0].r + freqdata[ncfft].r;
  cfg.tmpbuf[0].i := freqdata[0].r - freqdata[ncfft].r;
  
  for k := 1 to ncfft div 2 do
  begin
    fk := freqdata[k];
    fnkc.r := freqdata[ncfft - k].r;
    fnkc.i := -freqdata[ncfft - k].i;
    
    fek.r := (fk.r + fnkc.r) * 0.5;
    fek.i := (fk.i + fnkc.i) * 0.5;
    tmp.r := (fk.r - fnkc.r) * 0.5;
    tmp.i := (fk.i - fnkc.i) * 0.5;
    
    // C_MUL(fok, tmp, cfg.super_twiddles[k-1])
    fok.r := tmp.r * cfg.super_twiddles[k-1].r - 
             tmp.i * cfg.super_twiddles[k-1].i;
    fok.i := tmp.r * cfg.super_twiddles[k-1].i + 
             tmp.i * cfg.super_twiddles[k-1].r;
    
    cfg.tmpbuf[k].r := fek.r + fok.r;
    cfg.tmpbuf[k].i := fek.i + fok.i;
    cfg.tmpbuf[ncfft - k].r := fek.r - fok.r;
    cfg.tmpbuf[ncfft - k].i := -(fek.i - fok.i);
  end;
  
  // Hacer IFFT
  kiss_fft(cfg.substate, cfg.tmpbuf, cfg.tmpbuf);
  
  // Desempaquetar
  for k := 0 to ncfft - 1 do
  begin
    timedata[2 * k] := cfg.tmpbuf[k].r;
    timedata[2 * k + 1] := cfg.tmpbuf[k].i;
  end;
end;

end.