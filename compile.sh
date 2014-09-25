#!/bin/bash

CurrentBranch=`git branch | awk 'BEGIN{FS=" "}{if ($1=="*") print $2}'`

while [ "$CurrentBranch" = "master" ]; do
  read -p "Do you wish to update the MASTER branch(YES/NO):" yn
  case $yn in
    [YES]* ) break;;
    [NO]* ) exit;;
    * ) echo 'Please answer YES or NO';;
  esac
done

CurrentPWD=`pwd`

###echo '===== Compiling ====='
###cd server
###SubModuleServer=`git branch | awk 'BEGIN{FS=" "}{if ($1=="*") print $2}'`
###gulp compile
###
###cd ../data
###SubModuleData=`git branch | awk 'BEGIN{FS=" "}{if ($1=="*") print $2}'`
###if [ "$2" = "all" ]
###then
###	echo "Fetching table"
###	git pull
###fi
###
###cd ..
###
echo '===== Updating black box ====='
SOURCES=(
"define.js"
"serializer.js"
"spell.js"
"unit.js"
"container.js"
"item.js"
"seed-random.js"
"commandStream.js"
"dungeon.js"
"trigger.js"
)

DST_BOX="blackbox/"
for itm in ${SOURCES[*]}
do
  cp -f build/${itm} ${DST_BOX}${itm}
  sed -i "s/require(/requires(/g" ${DST_BOX}${itm}
  sed -i "s/var\ dbLib/\/\/var\ dbLib/g" ${DST_BOX}${itm}
  sed -i "s/dbWrapper'/serializer'/g" ${DST_BOX}${itm}
  sed -i "s/\.DBWrapper/\.Serializer/g" ${DST_BOX}${itm}
#  sed -ig 's/exports\.fileVersion = -1/exports\.fileVersion = '$CurrentVersion'/g' ${DST_BOX}${itm}
done

cp data/table/*.js build/
cp data/stable/*.js build/

cd server
cp js/*.js $CurrentPWD/build
cp src/*.js $CurrentPWD/build
cp src/*.js js/
cp package.json $CurrentPWD/build
cd ..

###echo '===== Setting up variables ====='
###if [ $CurrentBranch = develop ]
###then
###  CDNVersionBucket='hotupdate'
###  RemoteRepo='origin'
###  UpdateUrl='http://hotupdate.qiniudn.com/'
###  ServerConfiguration='Develop'
###  ServerID=0
###elif [ $CurrentBranch = master ]
###then
###  CDNVersionBucket='drhu'
###  RemoteRepo='deploy0'
###  UpdateUrl='http://drhu.qiniudn.com/'
###  ServerConfiguration='Master'
###  ServerID=1
###elif [[ $CurrentBranch = localWork ]]
###then
###  CDNVersionBucket='hotupdate'
###  RemoteRepo='deploy'
###  UpdateUrl='http://hotupdate.qiniudn.com/'
###  ServerConfiguration='Develop'
###  ServerID=0
###else
###  echo 'Invalid target branch'
###  exit
###fi
###
###
###VersionFile="build/version.js"
###CurrentVersion='not set'
####CurrentVersion=`curl -s $UpdateUrl/version`
####echo 'Current version: '$CurrentVersion
###sed -ig 's#"url":.*,#"url": "'$UpdateUrl'",#g' $VersionFile
###sed -ig 's/"resource_version": .*,/"resource_version": '$CurrentVersion',/g' $VersionFile
###sed -ig 's/"ServerName": .*,/"ServerName": "'$ServerConfiguration'",/g' $ConfigFile
###sed -ig 's/"ServerID": .*,/"ServerID": "'$ServerID'",/g' $ConfigFile
###
echo 'mulity version '
SEARCH_DIR=(
"build"
)

#if file name with -trin ,then it must be mulity version file.
#but if can't find file's name with -xxx. use xxx-trin as default

for dir in ${SEARCH_DIR[*]}
do
  mulityVersionFileList=`(ls $dir/*-trin.*)`

  for fileWithPath in $mulityVersionFileList
  do
          targetFile=`(basename $fileWithPath | sed -e 's/-trin//g')`
          wantFile=`(echo $fileWithPath | sed -e 's/-trin/-'$1'/g')`
          if [ -e $wantFile ]
          then
        	  sourceFile=$wantFile
          else
        	  sourceFile=$fileWithPath
          fi
          echo $wantFile '-----' $targetFile
          echo cp $sourceFile $targetFile
          #cp $sourceFile $targetfile
  done
done


# Commit
echo '===== Commit the changes ====='
echo 'Commit changes branch:'$CurrentBranch @ $CurrentVersion  Server: $SubModuleServer Table: $SubModuleData
git commit -am "Commit changes branch:"$CurrentBranch" @ "$CurrentVersion" Server:"$SubModuleServer" Table:"$SubModuleData

git push $RemoteRepo
