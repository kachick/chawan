import os
when defined(profile):
  import nimprof

import client
import config/config
import utils/twtstr

readConfig()
width_table = makewidthtable(gconfig.ambiguous_double)
newClient().launchClient(commandLineParams())
