-- Make the newly installed lifecycle RPCs immediately visible to PostgREST.
notify pgrst, 'reload schema';
