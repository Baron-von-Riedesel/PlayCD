
# create CD players
# PLAYCD: uses the "PLAY CD" command
# SB16CD: uses raw mode read long commands.

name1 = SB16CD
name2 = PLAYCD

DEBUG=0

OUTDIR=Build

ALL: $(OUTDIR) $(OUTDIR)\$(name1).exe $(OUTDIR)\$(name2).exe

$(OUTDIR):
	@mkdir $(OUTDIR)

$(OUTDIR)\$(name1).exe: $(name1).asm
	@jwasm -mz -nologo -Fl$* -Fo$* -IInclude $(name1).asm

$(OUTDIR)\$(name2).exe: $(name2).asm
	@jwasm -mz -nologo -Fl$* -Fo$* -IInclude $(name2).asm
