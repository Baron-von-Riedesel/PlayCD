@echo off
jwasm -mz -nologo -Fl=Build\ -Fo=Build\ -IInclude SB16CD.asm
jwasm -mz -nologo -Fl=Build\ -Fo=build\ -IInclude PlayCD.asm
jwasm -mz -nologo -Fl=Build\ -Fo=build\ -IInclude RippCD.asm
