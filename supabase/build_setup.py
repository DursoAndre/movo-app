#!/usr/bin/env python3
"""Junta os arquivos de supabase/sql/ (na ordem de supabase/ordem.txt) em supabase/setup_completo.sql.
Uso: python3 supabase/build_setup.py   (de qualquer pasta). Também avisa de arquivos fora da ordem."""
import os, sys
aqui = os.path.dirname(os.path.abspath(__file__))
sqld = os.path.join(aqui, "sql")
ordem = [l.strip() for l in open(os.path.join(aqui, "ordem.txt"), encoding="utf-8") if l.strip() and not l.startswith("#")]
existentes = sorted(f for f in os.listdir(sqld) if f.endswith(".sql"))
faltando = [f for f in ordem if f not in existentes]
sobrando = [f for f in existentes if f not in ordem]
if faltando or sobrando:
    print("ERRO: ordem.txt fora de sincronia com sql/")
    if faltando: print("  na ordem mas sem arquivo:", faltando)
    if sobrando: print("  arquivo fora da ordem:", sobrando)
    sys.exit(1)
out = ["-- Movo: setup completo do banco (gerado por supabase/build_setup.py — não edite; edite os arquivos de supabase/sql/).",
       "-- Para um projeto Supabase NOVO, cole tudo no SQL Editor e rode. Em produção NÃO precisa: tudo já está aplicado.", ""]
for f in ordem:
    out.append("-- " + "=" * 70)
    out.append("-- " + f)
    out.append("-- " + "=" * 70)
    out.append(open(os.path.join(sqld, f), encoding="utf-8").read().rstrip() + "\n")
open(os.path.join(aqui, "setup_completo.sql"), "w", encoding="utf-8").write("\n".join(out))
print("ok:", len(ordem), "arquivos ->", os.path.join(aqui, "setup_completo.sql"))
