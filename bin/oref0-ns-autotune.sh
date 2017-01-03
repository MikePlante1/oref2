#!/bin/bash

# This sccript sets up an easy test environment for autotune, allowing the user to vary parameters 
# like start/end date and number of runs.
# 
# Required Inputs: 
#   DIR, (--dir=<OpenAPS Directory>)
#   NIGHTSCOUT_HOST, (--ns-host=<NIGHTSCOUT SITE URL)
#   START_DATE, (--start-date=<YYYY-MM-DD>)
# Optional Inputs:
#   END_DATE, (--end-date=<YYYY-MM-DD>) 
#     if no end date supplied, assume we want a months worth or until day before current day
#   NUMBER_OF_RUNS (--runs=<integer, number of runs desired>)
#     if no number of runs designated, then default to 5
#   EXPORT_EXCEL (--xlsx=<filenameofexcel>)
#     export to excel. Disabled by default
#
# Released under MIT license. See the accompanying LICENSE.txt file for
# full terms and conditions
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

die() {
  echo "$@"
  exit 1
}

# defaults
DIR=""
NIGHTSCOUT_HOST=""
START_DATE=""
END_DATE=""
NUMBER_OF_RUNS=1  # Default to a single run if not otherwise specified
EXPORT_EXCEL="" # Default is to not export to Microsoft Excel
UNKNOWN_OPTION=""


# handle input arguments
for i in "$@"
do
case $i in
    -d=*|--dir=*)
    DIR="${i#*=}"
    # ~/ paths have to be expanded manually
    DIR="${DIR/#\~/$HOME}"
    directory="$(readlink -m $DIR)"
    shift # past argument=value
    ;;
    -n=*|--ns-host=*)
    NIGHTSCOUT_HOST="${i#*=}"
    shift # past argument=value
    ;;
    -s=*|--start-date=*)
    START_DATE="${i#*=}"
    START_DATE=`date --date="$START_DATE" +%Y-%m-%d`
    shift # past argument=value
    ;;
    -e=*|--end-date=*)
    END_DATE="${i#*=}"
    END_DATE=`date --date="$END_DATE" +%Y-%m-%d`
    shift # past argument=value
    ;;
    -r=*|--runs=*)
    NUMBER_OF_RUNS="${i#*=}"
    shift # past argument=value
    ;;
    -x=*|--xlsx=*)
    EXPORT_EXCEL="${i#*=}"
    shift # past argument=value
    ;;
    *)
    # unknown option
    echo "Option ${i#*=} unknown"
    UNKNOWN_OPTION="yes"
    ;;
esac
done

if [[ -z "$DIR" || -z "$NIGHTSCOUT_HOST" ]]; then
    echo "Usage: oref0-ns-autotune <--dir=openaps_directory> <--ns-host=https://mynightscout.azurewebsites.net> [--start-date=YYYY-MM-DD] [--end-date=YYYY-MM-DD] [--runs=number_of_runs] [--xlsx=autotune.xlsx]"
exit 1
fi
if [[ -z "$START_DATE" ]]; then
    # Default start date of yesterday
    START_DATE=`date --date="1 day ago" +%Y-%m-%d`
fi
if [[ -z "$END_DATE" ]]; then
    # Default end-date as this morning at midnight in order to not get partial day samples for now
    # (ISF/CSF adjustments are still single values across each day)
    END_DATE=`date --date="1 day ago" +%Y-%m-%d`
fi

if [[ -z "$UNKNOWN_OPTION" ]] ; then # everything is ok
  echo "Running oref0-autotune-test.sh --dir=$DIR --ns-host=$NIGHTSCOUT_HOST --start-date=$START_DATE --runs=$NUMBER_OF_RUNS --end-date=$END_DATE"
else
  echo "Unknown options. Exiting"
  exit 1
fi


# Get profile for testing copied to home directory. "openaps" is my loop directory name.
cd $directory && mkdir -p autotune
cp settings/pumpprofile.json autotune/profile.pump.json
# If a previous valid settings/autotune.json exists, use that; otherwise start from settings/profile.json
cp settings/autotune.json autotune/profile.json && cat autotune/profile.json | json | grep -q start || cp autotune/profile.pump.json autotune/profile.json
cd autotune
# TODO: Need to think through what to remove in the autotune folder...

# Pull Nightscout Data
echo "Grabbing NIGHTSCOUT treatments.json for date range..."

# Get Nightscout carb and insulin Treatments
curl "$NIGHTSCOUT_HOST/api/v1/treatments.json?find\[created_at\]\[\$gte\]=`date -d $START_DATE -Iminutes`&\[\$lte\]=`date -d $END_DATE -Iminutes`" > ns-treatments.json

# Build date list for autotune iteration
date_list=()
date=$START_DATE; 
while :
do 
  date_list+=( "$date" )
  if [ $date != "$END_DATE" ]; then 
    date="$(date --date="$date + 1 days" +%Y-%m-%d)"; 
  else 
    break
  fi
done

echo "Grabbing NIGHTSCOUT entries/sgv.json for date range..."

# Get Nightscout BG (sgv.json) Entries
for i in "${date_list[@]}"
do 
  curl "$NIGHTSCOUT_HOST/api/v1/entries/sgv.json?find\[date\]\[\$gte\]=`(date -d $i +%s | tr -d '\n'; echo 000)`&find\[date\]\[\$lte\]=`(date --date="$i +1 days" +%s | tr -d '\n'; echo 000)`&count=1000" > ns-entries.$i.json
done

echo "Running $NUMBER_OF_RUNS runs from $START_DATE to $END_DATE"
sleep 2

# Do iterative runs over date range, save autotune.json (prepped data) and input/output 
# profile.json
# Loop 1: Run 1 to Number of Runs specified by user or by default (1)
for run_number in $(seq 1 $NUMBER_OF_RUNS)
do
  # Loop 2: Iterate through Date Range
  for i in "${date_list[@]}"
  do
    cp profile.json profile.$run_number.$i.json
    # Autotune Prep (required args, <pumphistory.json> <profile.json> <glucose.json>), output prepped glucose 
    # data or <autotune/glucose.json> below
    echo "~/src/oref0/bin/oref0-autotune-prep.js ns-treatments.json profile.json ns-entries.$i.json > autotune.$run_number.$i.json"
    ~/src/oref0/bin/oref0-autotune-prep.js ns-treatments.json profile.json ns-entries.$i.json > autotune.$run_number.$i.json
    
    # Autotune  (required args, <autotune/glucose.json> <autotune/autotune.json> <settings/profile.json>), 
    # output autotuned profile or what will be used as <autotune/autotune.json> in the next iteration
    echo "~/src/oref0/bin/oref0-autotune.js autotune.$run_number.$i.json profile.json profile.pump.json > newprofile.$run_number.$i.json"
    ~/src/oref0/bin/oref0-autotune.js autotune.$run_number.$i.json profile.json profile.pump.json > newprofile.$run_number.$i.json
    
    # Copy tuned profile produced by autotune to profile.json for use with next day of data
    cp newprofile.$run_number.$i.json profile.json

  done # End Date Range Iteration
done # End Number of Runs Loop

if ! [[ -z "$EXPORT_EXCEL" ]]; then
  echo Exporting to $EXPORT_EXCEL
  oref0_autotune_export_to_xlsx --dir $DIR/autotune --output $EXPORT_EXCEL
fi
