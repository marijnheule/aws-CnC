import re
import subprocess
import sys
from os import listdir, environ
from os.path import isfile, join

HOST_FILE_PATH="/tmp/"
external_ips = []
onlyfiles = [f for f in listdir(HOST_FILE_PATH) if isfile(join(HOST_FILE_PATH, f))]
combined_text = ""

for filename in onlyfiles:
    if "hostfile" in filename:
        with open(join(HOST_FILE_PATH, filename)) as f:
            combined_text+=f.read()
with open("combined_hostfile", "w") as f:
    f.write(combined_text)

total_cores = 0
for l in combined_text.split("\n"):
    if "slots=" in l:
        total_cores+=int(l.split("slots=")[1])
print(total_cores)
