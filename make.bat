@echo off
jwasm -mz -nologo -Sg -Fl=Build\ -Fo=Build\ -IInclude SB16CD.asm
jwasm -mz -nologo -Sg -Fl=Build\ -Fo=build\ -IInclude PlayCD.asm
jwasm -mz -nologo -Sg -Fl=Build\ -Fo=build\ -IInclude RippCD.asm
