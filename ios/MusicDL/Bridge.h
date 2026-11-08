#ifndef MusicDL_Bridge_h
#define MusicDL_Bridge_h
// Ownership: every returned UTF-8 string must be released with MusicDLFree.
char *MusicDLStart(char *root);
char *MusicDLResolve(char *song, int fallback);
void MusicDLFree(char *value);
#endif
