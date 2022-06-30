#!/bin/bash

BASEDIR=$(dirname "$0")
cd $BASEDIR
CURRENT=$(pwd)
echo $CURRENT

source ../../common/common-utils.sh

namespace=$(cat ../../common/aiops-config.json | jq -r '.aiopsNamespace')


# Delete previous recent backup data 
echo "Deleting previous recent backup data..."
oc exec zen-metastoredb-0 -n $namespace -- bash -c "rm -rf /user-home/zen-metastoredb-backup/*.sql"


# Execute metastore backup 
echo "Executing the backup for metastore now...."
oc exec zen-metastoredb-0 -n $namespace -- bash -c "/tmp/backup/backup_script.sh"

if [ $? -eq 0 ]; then
   echo "Execution of metastore backup succeeded"

else
   echo "Execution of metastore backup failed, hence exiting!"
   exit 1
fi


# Verify that metastore backup data exist in the pod
echo "Verifying that if backup data exists after metastore backup succeeded"
#oc exec  zen-metastoredb-0 -n $namespace -- bash -c "ls -altr /user-home/zen-metastoredb-backup"
BACKUPFILEMEZSSAGE=$(oc exec  zen-metastoredb-0 -n $namespace  -- bash -c 'if [[ $(ls -A /user-home/zen-metastoredb-backup) ]]; then echo "There are backup files"; else echo "No backup files found"; fi')

if [[ $BACKUPFILEMEZSSAGE == "There are backup files" ]]; then
  echo $BACKUPFILEMEZSSAGE
else
  echo "$BACKUPFILEMEZSSAGE, hence existing!"
  exit 1
fi

#Creating metastore backup pod and pvc
echo "Creating metastore backup pod and pvc"
oc create -f metastore-backup.yaml -n $namespace

# Make sure backup-metastore is running
echo " Checking if backup-metastore is running"
checkPodReadyness $namespace "component=backup-metastore" "60"


# Move the backup file from metastore pod to backup-metastore pod
{  # try
   oc exec zen-metastoredb-0 -n $namespace -- bash -c "cd /user-home/zen-metastoredb-backup && tar cf zen-metastoredb-backup.tar *" &&
   oc cp -n $namespace zen-metastoredb-0:/user-home/zen-metastoredb-backup/zen-metastoredb-backup.tar /tmp/zen-metastoredb-backup.tar &&
   oc cp -n $namespace /tmp/zen-metastoredb-backup.tar backup-metastore:/usr/share/backup/zen-metastoredb-backup.tar &&
   echo "Backup file from metastore pod to backup-metastore pod transferred!" &&
   echo "Backing up jwt token" &&
   oc exec zen-metastoredb-0 -n $namespace -- bash -c "cd /user-home/_global_/config/ && tar cf jwt.tar jwt" &&
   oc cp -n $namespace zen-metastoredb-0:/user-home/_global_/config/jwt.tar /tmp/jwt.tar &&
   oc exec zen-metastoredb-0 -n $namespace -- bash -c "rm -rf /user-home/_global_/config/jwt.tar" &&
   oc cp -n $namespace /tmp/jwt.tar backup-metastore:/usr/share/backup/jwt.tar  &&
   echo "JWT Backup file from metastore pod to backup-metastore pod transferred!"
} || { # catch
   echo "Transfer of backup file to backup-metastore pod failed, hence exiting!"
   echo "Deleting metastore backup pod and pvc"
   oc delete -f metastore-backup.yaml -n $namespace
   exit 1
}

# Taking backup of SERVICE_INSTANCE_ID
service_instance_id=$(oc get deploy aimanager-aio-controller -o jsonpath='{.spec.template.spec.containers[?(@.name == "controller")].env[?(@.name == "SERVICE_INSTANCE_ID")].value}' -n $namespace)
echo "SERVICE_INSTANCE_ID value is $service_instance_id"

# Creating a configmap to store the mongodb_dump_image
oc delete configmap metastore-bcdr-config -n $namespace 2> /dev/null
oc create configmap metastore-bcdr-config --from-literal=serviceInstanceId=$service_instance_id -n $namespace
