/*
 * MiniDarwin does not implement the private I/O policy query. Returning the
 * default value keeps removefile's dataless-file optimization disabled.
 */
__attribute__((visibility("hidden")))
int
getiopolicy_np(int type, int scope)
{
  (void)type;
  (void)scope;
  return -1;
}
