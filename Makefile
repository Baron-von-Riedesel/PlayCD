
# CD players:
# PLAYCD: uses the "PLAY CD" command
# SB16CD: uses raw mode read long commands.
# CD rippers:
# RippCD: use raw mode read long to read.

name1 = PlayCD
name2 = SB16CD
name3 = RippCD

DEBUG=0

OUTDIR=Build

ALL: $(OUTDIR) $(OUTDIR)\$(name1).exe $(OUTDIR)\$(name2).exe $(OUTDIR)\$(name3).exe

$(OUTDIR):
	@mkdir $(OUTDIR)

$(OUTDIR)\$(name1).exe: $(name1).asm
	@jwasm -mz -nologo -Fl$* -Fo$* -IInclude $(name1).asm

$(OUTDIR)\$(name2).exe: $(name2).asm
	@jwasm -mz -nologo -Fl$* -Fo$* -IInclude $(name2).asm

$(OUTDIR)\$(name3).exe: $(name3).asm
	@jwasm -mz -nologo -Fl$* -Fo$* -IInclude $(name3).asm
