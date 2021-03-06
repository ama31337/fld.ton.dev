#!/bin/bash

# (C) Sergey Tyurin  2020-09-01 12:00:00

# You have to have installed :
#   'xxd' - is a part of vim-commons ( [apt/dnf/pkg] install vim[-common] )
#   'jq'
#   'bc' for Linux
#   'dc' for FreeBSD
#   'tvm_linker' compiled binary from https://github.com/tonlabs/TVM-linker.git to $HOME/bin (must be in $PATH)
#   'lite-client'                                               
#   'validator-engine-console'
#   'fift'

# Disclaimer
##################################################################################################################
# You running this script/function means you will not blame the author(s)
# if this breaks your stuff. This script/function is provided AS IS without warranty of any kind. 
# Author(s) disclaim all implied warranties including, without limitation, 
# any implied warranties of merchantability or of fitness for a particular purpose. 
# The entire risk arising out of the use or performance of the sample scripts and documentation remains with you.
# In no event shall author(s) be held liable for any damages whatsoever 
# (including, without limitation, damages for loss of business profits, business interruption, 
# loss of business information, or other pecuniary loss) arising out of the use of or inability 
# to use the script or documentation. Neither this script/function, 
# nor any part of it other than those parts that are explicitly copied from others, 
# may be republished without author(s) express written permission. 
# Author(s) retain the right to alter this disclaimer at any time.
##################################################################################################################

set -o pipefail

if [ "$DEBUG" = "yes" ]; then
    set -x
fi

####################################
# we can't work on desynced node
TIMEDIFF_MAX=100
MAX_FACTOR=${MAX_FACTOR:-3}
####################################

echo
echo "#################################### Depool INFO script ########################################"
echo "INFO: $(basename "$0") BEGIN $(date +%s) / $(date)"

SCRIPT_DIR=`cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P`

. "${SCRIPT_DIR}/env.sh"

CALL_LC="${TON_BUILD_DIR}/lite-client/lite-client -p ${KEYS_DIR}/liteserver.pub -a 127.0.0.1:3031 -t 5"
CALL_VC="${TON_BUILD_DIR}/validator-engine-console/validator-engine-console -k ${KEYS_DIR}/client -p ${KEYS_DIR}/server.pub -a 127.0.0.1:3030 -t 5"
CALL_TL="$HOME/bin/tvm_linker"
CALL_FT="${TON_BUILD_DIR}/crypto/fift -I ${TON_SRC_DIR}/crypto/fift/lib:${TON_SRC_DIR}/crypto/smartcont"
OS_SYSTEM=`uname`
if [[ "$OS_SYSTEM" == "Linux" ]];then
    CALL_BC="bc"
else
    CALL_BC="bc -l"
fi

##############################################################################
# Test binaries
if [[ -z $($CALL_TL -V | grep "TVM linker") ]];then
    echo "###-ERROR: TVM linker not installed in PATH"
    exit 1
fi

if [[ -z $(xxd -v 2>&1 | grep "Juergen Weigert") ]];then
    echo "###-ERROR: 'xxd' not installed in PATH"
    exit 1
fi

if [[ -z $(jq --help 2>/dev/null |grep -i "Usage"|cut -d ":" -f 1) ]];then
    echo "###-ERROR: 'jq' not installed in PATH"
    exit 1
fi
#=================================================
# Check 'getvalidators' command present in engine
Node_Keys=`$CALL_VC -c "getvalidators" -c "quit" 2>/dev/null | grep "validator0"`

if [[ -z $Node_Keys ]];then
    echo "###-ERROR: You engine hasn't command 'getvalidators'. Get & install new engine from 'https://github.com/FreeTON-Network/FreeTON-Node'"
#    exit 1
fi

##############################################################################
# Functions
# ================================================
function TD_unix2human() {
    local OS_SYSTEM=`uname`
    local ival="$(echo ${1}|tr -d '"')"
    if [[ "$OS_SYSTEM" == "Linux" ]];then
        echo "$(date  +'%F %T %Z' -d @$ival)"
    else
        echo "$(date -r $ival +'%F %T %Z')"
    fi
}
#=================================================
# NOTE: Avoid double quoting  - ""0xXXXXX"" in input var
function hex2dec() {
    local OS_SYSTEM=`uname`
    local ival="$(echo ${1^^}|tr -d '"')"
    local ob=${2:-10}
    local ib=${3:-16}
    if [[ "$OS_SYSTEM" == "Linux" ]];then
        export BC_LINE_LENGTH=0
        # set obase first before ibase -- or weird things happen.
        printf "obase=%d; ibase=%d; %s\n" $ob $ib $ival | bc
    else
        dc -e "${ib}i ${ival} p" | tr -d "\\" | tr -d "\n"
    fi
}
#=================================================
# Get Smart Contract current state by dowloading it & save to file
function Get_SC_current_state() { 
    # Input: acc in form x:xxx...xxx
    # result: file named xxx...xxx.tvc
    # return: Output of lite-client executing
    local w_acc="$1" 
    [[ -z $w_acc ]] && echo "###-ERROR: func Get_SC_current_state: empty address" && exit 1
    local s_acc=`echo "${w_acc}" | cut -d ':' -f 2`
    rm -f ${s_acc}.tvc
    trap 'echo LC TIMEOUT EXIT' EXIT
    local LC_OUTPUT=`$CALL_LC -rc "saveaccount ${s_acc}.tvc ${w_acc}" -rc "quit" 2>/dev/null`
    trap - EXIT
    local result=`echo $LC_OUTPUT | grep "written StateInit of account"`
    if [[ -z  $result ]];then
        echo "###-ERROR: Cannot get account state. Can't continue. Sorry."
        exit 1
    fi
    echo "$LC_OUTPUT"
}
#=================================================
# Get middle number
function getmid() {
  if (( $1 <= $2 )); then
     (( $1 >= $3 )) && { echo $1; return; }
     (( $2 <= $3 )) && { echo $2; return; }
  fi;
  if (( $1 >= $2 )); then
     (( $1 <= $3 )) && { echo $1; return; }
     (( $2 >= $3 )) && { echo $2; return; }
  fi;
  echo $3;
}
# Get first number
function getfst() {
  if (( $1 <= $2 )); then
     (( $1 <= $3 )) && { echo $1; return; }
  fi;
  if (( $2 <= $1 )); then
     (( $2 <= $3 )) && { echo $2; return; }
  fi;
  echo $3;
}
# Get last number
function getnxt() {
  if (( $1 >= $2 )); then
     (( $1 >= $3 )) && { echo $1; return; }
  fi;
  if (( $2 >= $1 )); then
     (( $2 >= $3 )) && { echo $2; return; }
  fi;
  echo $3;
}
##############################################################################
# Load addresses and set variables
Depool_addr=`cat ${KEYS_DIR}/depool.addr`
dpc_addr=`echo $Depool_addr | cut -d ':' -f 2`
Helper_addr=`cat ${KEYS_DIR}/helper.addr`
Proxy0_addr=`cat ${KEYS_DIR}/proxy0.addr`
Proxy1_addr=`cat ${KEYS_DIR}/proxy1.addr`
Validator_addr=`cat ${KEYS_DIR}/${VALIDATOR_NAME}.addr`
Work_Chain=`echo "${Validator_addr}" | cut -d ':' -f 1`

if [[ -z $Validator_addr ]];then
    echo "###-ERROR: Can't find validator address! ${KEYS_DIR}/${VALIDATOR_NAME}.addr"
    exit 1
fi
if [[ -z $Depool_addr ]];then
    echo "###-ERROR: Can't find depool address! ${KEYS_DIR}/depool.addr"
    exit 1
fi

val_acc_addr=`echo "${Validator_addr}" | cut -d ':' -f 2`
echo "INFO: validator account address: $Validator_addr"
echo "INFO: depool   contract address: $Depool_addr"
ELECTIONS_WORK_DIR="${KEYS_DIR}/elections"
[[ ! -d ${ELECTIONS_WORK_DIR} ]] && mkdir -p ${ELECTIONS_WORK_DIR}
chmod +x ${ELECTIONS_WORK_DIR}

DSCs_DIR="$NET_TON_DEV_SRC_TOP_DIR/ton-labs-contracts/solidity/depool"

##############################################################################
# Check node sync
VEC_OUTPUT=`$CALL_VC -c "getstats" -c "quit"`

CURR_TD_NOW=`echo "${VEC_OUTPUT}" | grep unixtime | awk '{print $2}'`
CHAIN_TD=`echo "${VEC_OUTPUT}" | grep masterchainblocktime | awk '{print $2}'`
TIME_DIFF=$((CURR_TD_NOW - CHAIN_TD))
if [[ $TIME_DIFF -gt $TIMEDIFF_MAX ]];then
    echo "###-ERROR: Your node is not synced. Wait until full sync (<$TIMEDIFF_MAX) Current timediff: $TIME_DIFF"
#    "${SCRIPT_DIR}/Send_msg_toTelBot.sh" "$HOSTNAME Server" "###-ERROR: Your node is not synced. Wait until full sync (<$TIMEDIFF_MAX) Current timediff: $TIME_DIFF" 2>&1 > /dev/null
    exit 1
fi
echo "INFO: Current TimeDiff: $TIME_DIFF"

##############################################################################
# get elector address
elector_addr=`$CALL_LC -rc "getconfig 1" -rc "quit" 2>/dev/null | grep -i 'ConfigParam(1)' | awk '{print substr($4,15,64)}'`
elector_addr=`echo "-1:"$elector_addr | tee ${ELECTIONS_WORK_DIR}/elector-addr-base64`
echo "INFO:     Elector Address: $elector_addr"

##############################################################################
# get elections ID from elector
echo
echo "==================== Elections Info ====================================="

election_id=`$CALL_LC -rc "runmethod $elector_addr active_election_id" -rc "quit" 2>/dev/null | grep "result:" | awk '{print $3}'`
echo "   => Elector Election ID: $election_id / $(echo "$election_id" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}')"
echo 

Node_Keys=`$CALL_VC -c "getvalidators" -c "quit" 2>/dev/null | grep "validator0"`

if [[ ! -z $Node_Keys ]];then
    Node_Keys=`$CALL_VC -c "getvalidators" -c "quit" 2>/dev/null`
    Curr_Engine_Eclec_ID=$(echo "$Node_Keys" | grep "validator0"| grep -i 'tempkey:' | awk '{print $2}')
    Curr_Engine_Pub_Key=$(echo  "$Node_Keys" | grep "validator0"| grep -i 'tempkey:' | awk '{print $4}'|tr "[:upper:]" "[:lower:]")
    Curr_Engine_ADNL_Key=$(echo "$Node_Keys" | grep "validator0"| grep -i 'adnl:'    | awk '{print $4}'|tr "[:upper:]" "[:lower:]")
    if [[ -z $(echo "$Node_Keys"|grep "validator1") ]];then
        echo "       Engine Election ID: $Curr_Engine_Eclec_ID / $(echo "$Curr_Engine_Eclec_ID" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}')"
        echo "Current Engine public key: $Curr_Engine_Pub_Key"
        echo "  Current Engine ADNL key: $Curr_Engine_ADNL_Key"
    else
        Next_Engine_Eclec_ID=$Curr_Engine_Eclec_ID
        Next_Engine_Pub_Key=$Curr_Engine_Pub_Key
        Next_Engine_ADNL_Key=$Curr_Engine_ADNL_Key
        Curr_Engine_Eclec_ID=$(echo "$Node_Keys" | grep "validator1"| grep -i 'tempkey:' | awk '{print $2}')
        Curr_Engine_Pub_Key=$(echo  "$Node_Keys" | grep "validator1"| grep -i 'tempkey:' | awk '{print $4}'|tr "[:upper:]" "[:lower:]")
        Curr_Engine_ADNL_Key=$(echo "$Node_Keys" | grep "validator1"| grep -i 'adnl:'    | awk '{print $4}'|tr "[:upper:]" "[:lower:]")

        echo "Current Engine Election #: $Curr_Engine_Eclec_ID / $(echo "$Curr_Engine_Eclec_ID" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}')"
        echo "Current Engine public key: $Curr_Engine_Pub_Key"
        echo "  Current Engine ADNL key: $Curr_Engine_ADNL_Key"
        echo
        echo "   Next Engine Election #: $Next_Engine_Eclec_ID / $(echo "$Next_Engine_Eclec_ID" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}')"
        echo "   Next Engine public key: $Next_Engine_Pub_Key"
        echo "     Next Engine ADNL key: $Next_Engine_ADNL_Key"
    fi
fi

##############################################################################
# Save DePool contract state to file
# echo -n "   Get SC state of depool: $Depool_addr ... "    
LC_OUTPUT="$(Get_SC_current_state "$Depool_addr")"
result=`echo $LC_OUTPUT | grep "written StateInit of account"`
if [[ -z  $result ]];then
    echo "###-ERROR: Cannot get account state. Can't continue. Sorry."
    exit 1
fi
# echo "Done."

##############################################################################
# get info from DePool contract state
Curr_Rounds_Info=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getRounds -p "{}" --decode-c6 $dpc_addr | grep -i 'rounds')
Current_Depool_Info=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getDePoolInfo -p "{}" --decode-c6 $dpc_addr|grep -i 'validatorWallet')

##############################################################################
# get Rounds info from DePool contract state
# "outputs": [
# 				{"components":[
# 					{"name":"id","type":"uint64"},
# 					{"name":"supposedElectedAt","type":"uint32"},
# 					{"name":"unfreeze","type":"uint32"},
# 					{"name":"step","type":"uint8"},
# 					{"name":"completionReason","type":"uint8"},
# 					{"name":"participantQty","type":"uint32"},
# 					{"name":"stake","type":"uint64"},
# 					{"name":"rewards","type":"uint64"},
# 					{"name":"unused","type":"uint64"},
# 					{"name":"start","type":"uint64"},
# 					{"name":"end","type":"uint64"},
# 					{"name":"vsetHash","type":"uint256"}
# 					],"name":"rounds","type":"map(uint64,tuple)"}
# 			]

Round_0_ID=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[0].id"|tr -d '"'| xargs printf "%d\n")
Round_1_ID=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[1].id"|tr -d '"'| xargs printf "%d\n")
Round_2_ID=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[2].id"|tr -d '"'| xargs printf "%d\n")

Prev_Round_ID=$(getfst "$Round_2_ID" "$Round_1_ID" "$Round_0_ID")
Curr_Round_ID=$(getmid "$Round_2_ID" "$Round_1_ID" "$Round_0_ID")
Next_Round_ID=$(getnxt "$Round_2_ID" "$Round_1_ID" "$Round_0_ID")

Prev_Round_Num=$((Prev_Round_ID - Round_0_ID))
Curr_Round_Num=$((Curr_Round_ID - Round_0_ID))
Next_Round_Num=$((Next_Round_ID - Round_0_ID))

# ------------------------------------------------------------------------------------------------------------------------
Prev_DP_Elec_ID=$(echo   "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].supposedElectedAt"|tr -d '"'| xargs printf "%d\n")
Prev_DP_Round_ID=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].id"|tr -d '"'| xargs printf "%d\n")
Prev_Round_P_QTY=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].participantQty"|tr -d '"'| xargs printf "%4d\n")
Prev_Round_Stake=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].stake"|tr -d '"'| xargs printf "%d\n")
Prev_Round_Revard=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].rewards"|tr -d '"'| xargs printf "%d\n")
Prev_Round_Stake=$(printf '%12.3f' "$(echo $Prev_Round_Stake / 1000000000 | jq -nf /dev/stdin)")
Prev_Round_Revard=$(printf '%12.3f' "$(echo $Prev_Round_Stake / 1000000000 | jq -nf /dev/stdin)")

Curr_DP_Elec_ID=$(echo   "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].supposedElectedAt"|tr -d '"'| xargs printf "%d\n")
Curr_Round_P_QTY=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].participantQty"|tr -d '"'| xargs printf "%4d\n")
Curr_DP_Round_ID=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].id"|tr -d '"'| xargs printf "%d\n")
Curr_Round_Stake=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].stake"|tr -d '"'| xargs printf "%d\n")
Curr_Round_Revard=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].rewards"|tr -d '"'| xargs printf "%d\n")
Curr_Round_Stake=$(printf '%12.3f' "$(echo $Curr_Round_Stake / 1000000000 | jq -nf /dev/stdin)")
Curr_Round_Revard=$(printf '%12.3f' "$(echo $Curr_Round_Stake / 1000000000 | jq -nf /dev/stdin)")

Next_DP_Elec_ID=$(echo   "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].supposedElectedAt"|tr -d '"'| xargs printf "%d\n")
Next_DP_Round_ID=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].id"|tr -d '"'| xargs printf "%d\n")
Next_Round_P_QTY=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].participantQty"|tr -d '"'| xargs printf "%4d\n")
Next_Round_Stake=$(echo  "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].stake"|tr -d '"'| xargs printf "%d\n")
Next_Round_Revard=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].rewards"|tr -d '"'| xargs printf "%d\n")
Next_Round_Stake=$(printf '%12.3f' "$(echo $Next_Round_Stake / 1000000000 | jq -nf /dev/stdin)")
Next_Round_Revard=$(printf '%12.3f' "$(echo $Next_Round_Stake / 1000000000 | jq -nf /dev/stdin)")

echo " --------------------------------------------------------------------------------------------------------------------------"
echo "|                 |           Prev Round             |           Current Round           |            Next Round           |"
echo " --------------------------------------------------------------------------------------------------------------------------"
echo "|            ID   | $Prev_DP_Elec_ID / $(echo "$Prev_DP_Elec_ID" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}') | $Curr_DP_Elec_ID / $(echo "$Curr_DP_Elec_ID" | gawk '{print strftime("%Y-%m-%d %H:%M:%S", $1)}') |                  $Next_DP_Elec_ID               |"
echo "| Participant QTY |               $Prev_Round_P_QTY               |               $Curr_Round_P_QTY               |               $Next_Round_P_QTY               |"
echo "|         Stake   |           $Prev_Round_Stake           |           $Curr_Round_Stake           |           $Next_Round_Stake           |"
echo "|        Revard   |           $Prev_Round_Revard           |           $Curr_Round_Revard           |           $Next_Round_Revard           |"


#######################################################################################
# Get Depool Info
# returns (
#         uint64 minStake,
#         uint64 minRoundStake,
#         uint64 minValidatorStake,
#         address validatorWallet,
#         address[] proxies,
#         bool poolClosed,
#         uint64 interest,
#         uint64 addStakeFee,
#         uint64 addVestingOrLockFee,
#         uint64 removeOrdinaryStakeFee,
#         uint64 withdrawPartAfterCompletingFee,
#         uint64 withdrawAllAfterCompletingFee,
#         uint64 transferStakeFee,
#         uint64 retOrReinvFee,
#         uint64 answerMsgFee,
#         uint64 proxyFee,
#         uint64 participantFraction,
#         uint64 validatorFraction,
#         uint64 validatorWalletMinStake


echo 
echo "==================== Current Depool State ====================================="

PoolClosed=$(echo "$Current_Depool_Info"|jq '.poolClosed'|tr -d '"')
if [[ "$PoolClosed" == "false" ]];then
    PoolState="OPEN for participation!"
else
    PoolState="CLOSED!!! all stakes should be return to participants"
fi
echo "Pool State: $PoolState"
echo
echo "================ Minimal Stakes for participant in the depool ================"

PoolMinStake=$(echo "$Current_Depool_Info"|jq '.minStake'|tr -d '"')
PoolMinRoundStake=$(echo "$Current_Depool_Info"|jq '.minRoundStake'|tr -d '"')
PoolValMinStake=$(echo "$Current_Depool_Info"|jq '.minValidatorStake'|tr -d '"')
PoolValWalMinStake=$(echo "$Current_Depool_Info"|jq '.validatorWalletMinStake'|tr -d '"')

echo "                Pool Min Stake (Tk): $((PoolMinStake / 1000000000))"
echo "  Pool Min Stake for one round (TK): $((PoolMinRoundStake / 1000000000))"
echo "  Pool Min Stake for validator (TK): $((PoolValMinStake / 1000000000))"
echo "Min Stake for validator wallet (TK): $((PoolValWalMinStake))"
echo
echo "============================ Depool fees ======================================"
PoolInterest=$(echo "$Current_Depool_Info"|jq '.interest'|tr -d '"')


echo "           Pool Last Round Interest (%): $(echo "scale=3; $((PoolInterest)) / 100000000" | $CALL_BC)"

echo
echo "=================== Current participants info in the depool ==================="

# tonos-cli run --abi ${DSCs_DIR}/DePool.abi.json $Depool_addr getParticipants {} > current_participants.lst
# Num_of_participants=`cat current_participants.lst | grep '"0:'| tr -d ' '|tr -d ',' |tr -d '"'| nl | tail -1 |awk '{print $1}'`
Num_of_participants=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipants -p "{}" --decode-c6 $dpc_addr | grep 'participants' | jq '.participants|length')
echo "Current Number of participants: $Num_of_participants"



Prev_Round_Part_QTY=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Prev_Round_Num].participantQty"|tr -d '"'| xargs printf "%d\n")
Curr_Round_Part_QTY=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Curr_Round_Num].participantQty"|tr -d '"'| xargs printf "%d\n")
Next_Round_Part_QTY=$(echo "$Curr_Rounds_Info" | jq "[.rounds[]]|.[$Next_Round_Num].participantQty"|tr -d '"'| xargs printf "%d\n")

echo "===== Rounds participants QTY (prev/curr/next): $((Prev_Round_Part_QTY + 1)) / $((Curr_Round_Part_QTY + 1)) / $((Next_Round_Part_QTY + 1))"
# "outputs": [
# 				{"name":"total","type":"uint64"},
# 				{"name":"withdrawValue","type":"uint64"},
# 				{"name":"reinvest","type":"bool"},
# 				{"name":"reward","type":"uint64"},
# 				{"name":"stakes","type":"map(uint64,uint64)"},
# 				{"components":[{"name":"isActive","type":"bool"},{"name":"amount","type":"uint64"},{"name":"lastWithdrawalTime","type":"uint64"},{"name":"withdrawalPeriod","type":"uint32"},{"name":"withdrawalValue","type":"uint64"},{"name":"owner","type":"address"}],"name":"vestings","type":"map(uint64,tuple)"},
# 				{"components":[{"name":"isActive","type":"bool"},{"name":"amount","type":"uint64"},{"name":"lastWithdrawalTime","type":"uint64"},{"name":"withdrawalPeriod","type":"uint32"},{"name":"withdrawalValue","type":"uint64"},{"name":"owner","type":"address"}],"name":"locks","type":"map(uint64,tuple)"}

Hex_Curr_Round_ID=$(echo "0x$(printf '%x\n' $Curr_Round_ID)")
Hex_Prev_Round_ID=$(echo "0x$(printf '%x\n' $Prev_Round_ID)")

CRP_QTY=$((Curr_Round_Part_QTY - 1))
for (( i=0; i <= $CRP_QTY; i++ ))
do
    Curr_Part_Addr=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipants -p "{}" --decode-c6 $dpc_addr | grep 'participants' | jq ".participants|.[$i]")
    Curr_Ord_Stake=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipantInfo -p "{\"addr\":$Curr_Part_Addr}" --decode-c6 $dpc_addr|grep -i 'withdrawValue' | jq ".stakes.\"$Hex_Curr_Round_ID\""|tr -d '"')
    Prev_Ord_Stake=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipantInfo -p "{\"addr\":$Curr_Part_Addr}" --decode-c6 $dpc_addr|grep -i 'withdrawValue' | jq ".stakes.\"$Hex_Prev_Round_ID\""|tr -d '"')
    Revard=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipantInfo -p "{\"addr\":$Curr_Part_Addr}" --decode-c6 $dpc_addr|grep -i 'withdrawValue' | jq ".reward"|tr -d '"')
    Curr_Lck_Stake=$($CALL_TL test -a ${DSCs_DIR}/DePool.abi.json -m getParticipantInfo -p "{\"addr\":$Curr_Part_Addr}" --decode-c6 $dpc_addr|grep -i 'withdrawValue' | jq ".locks.\"$Hex_Curr_Round_ID\".amount" |tr -d '"')

    echo "$(printf '%4d' $(($i + 1))) $Curr_Part_Addr Revard: $((Revard / 1000000000)) ;  Stakes: $((Prev_Ord_Stake / 1000000000)) / $((Curr_Ord_Stake / 1000000000)) ; Lock: $((Curr_Lck_Stake / 1000000000))"
done


PoolPartsFrac=$(echo "$Current_Depool_Info"|jq '.participantFraction'|tr -d '"')
PoolValFrac=$(echo "$Current_Depool_Info"|jq '.validatorFraction'|tr -d '"')


echo "Pool participants fraction: $((PoolValWalMinStake))"
echo "   Pool validator fraction: $((PoolValFrac))"


echo "=========================================================================================="


echo "INFO: $(basename "$0") FINISHED $(date +%s) / $(date)"

trap - EXIT
exit 0


