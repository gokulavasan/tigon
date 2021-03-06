#!/usr/bin/env bash

# Copyright © 2014 Cask Data, Inc.
# 
# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.
  
# Build script for docs
# Builds the docs (all except javadocs and PDFs) from the .rst source files using Sphinx
# Builds the javadocs and copies them into place
# Zips everything up so it can be staged
# REST PDF is built as a separate target and checked in, as it is only used in SDK and not website
# Target for building the SDK
# Targets for both a limited and complete set of javadocs
# Targets not included in usage are intended for internal usage by script

DATE_STAMP=`date`
SCRIPT=`basename $0`

SOURCE="source"
BUILD="build"
BUILD_PDF="build-pdf"
BUILD_TEMP="build-temp"
HTML="html"
INCLUDES="_includes"

API="tigon-api"
APIS="apis"
APIDOCS="apidocs"
JAVADOCS="javadocs"
LICENSES="licenses"
LICENSES_PDF="licenses-pdf"
PROJECT="tigon"
PROJECT_CAPS="Tigon"
EXAMPLES="examples"
TIGON_EXAMPLES="tigon-examples"

SCRIPT_PATH=`pwd`

SOURCE_PATH="$SCRIPT_PATH/$SOURCE"
BUILD_PATH="$SCRIPT_PATH/$BUILD"
HTML_PATH="$BUILD_PATH/$HTML"

BUILD_APIS="$BUILD_PATH/$HTML/$APIS"

DOC_GEN_PY="$SCRIPT_PATH/../tools/doc-gen.py"

REST_SOURCE="$SOURCE_PATH/rest.rst"
REST_PDF="$SCRIPT_PATH/$BUILD_PDF/rest.pdf"

if [ "x$2" == "x" ]; then
  PROJECT_PATH="$SCRIPT_PATH/../../"
else
  PROJECT_PATH="$2"
fi
PROJECT_JAVADOCS="$PROJECT_PATH/target/site/apidocs"
SDK_JAVADOCS="$PROJECT_PATH/$API/target/site/$APIDOCS"
FULL_JAVADOCS="$PROJECT_PATH/target/site/$APIDOCS"

# Set Google Analytics Codes
# Corporate Docs Code
GOOGLE_ANALYTICS_WEB="UA-55077523-3"
WEB="web"
# Tigon Project Code
GOOGLE_ANALYTICS_GITHUB="UA-55081520-4"
GITHUB="github"

REDIRECT_EN_HTML=`cat <<EOF
<!DOCTYPE HTML>
<html lang="en-US">
    <head>
        <meta charset="UTF-8">
        <meta http-equiv="refresh" content="0;url=en/index.html">
        <script type="text/javascript">
            window.location.href = "en/index.html"
        </script>
        <title></title>
    </head>
    <body>
    </body>
</html>
EOF`

function usage() {
  cd $PROJECT_PATH
  PROJECT_PATH=`pwd`
  echo "Build script for '$PROJECT_CAPS' docs"
  echo "Usage: $SCRIPT < option > [source]"
  echo ""
  echo "  Options (select one)"
  echo "    all            Clean build of everything: HTML docs and Javadocs, GitHub and Web versions"
  echo "    build          Clean build of javadocs and HTML docs, copy javadocs into place, zip results"
  echo "    build-includes Clean conversion of example/README.md to _includes directory reST files"
  echo "    build-quick    Clean build of HTML docs, copy existing javadocs into place"
  echo "    build-github   Clean build and zip for placing on GitHub"
  echo "    build-web      Clean build and zip for placing on docs.cask.co webserver"
  echo ""
  echo "    docs           Clean build of docs"
  echo "    javadocs       Clean build of javadocs (selected modules only) for SDK and website"
  echo "    javadocs-full  Clean build of javadocs for all modules"
  echo "    zip            Zips docs into an archive"
  echo ""
  echo "    check-includes Check if included files have changed from source"
  echo "    depends        Build Site listing dependencies"
  echo "    sdk            Build SDK"
  echo "  with"
  echo "    source         Path to $PROJECT source for javadocs, if not $PROJECT_PATH"
  echo " "
  exit 1
}

function clean() {
  cd $SCRIPT_PATH
  rm -rf $SCRIPT_PATH/$BUILD
  mkdir $SCRIPT_PATH/$BUILD
}

function build_docs() {
  clean
  cd $SCRIPT_PATH
  check_includes
  sphinx-build -b html -d build/doctrees source build/html
}

function build_docs_google() {
  clean
  cd $SCRIPT_PATH
  check_includes
  sphinx-build -D googleanalytics_id=$1 -D googleanalytics_enabled=1 -b html -d build/doctrees source build/html
}

function build_javadocs() {
  cd $PROJECT_PATH
  mvn clean install -DskipTests -Dgpg.skip=true
  mvn site -DskipTests -Dgpg.skip=true
}

function copy_javadocs() {
  cd $BUILD_APIS
  rm -rf $JAVADOCS
  cp -r $FULL_JAVADOCS .
  mv -f $APIDOCS $JAVADOCS
}

function build_javadocs_selected() {
  cd $PROJECT_PATH
  mvn clean package javadoc:javadoc -pl tigon-api -pl tigon-flow -pl tigon-sql -am -DskipTests -P release
}

function make_zip_html() {
  version
  ZIP_FILE_NAME="$PROJECT-docs-$PROJECT_VERSION.zip"
  cd $SCRIPT_PATH/$BUILD
  zip -r $ZIP_FILE_NAME $HTML/*
}

function make_zip() {
# This creates a zip that unpacks to the same name
  version
  if [ "x$1" == "x" ]; then
    ZIP_DIR_NAME="$PROJECT-docs-$PROJECT_VERSION"
  else
    ZIP_DIR_NAME="$PROJECT-docs-$PROJECT_VERSION-$1"
  fi  
  cd $SCRIPT_PATH/$BUILD
  mv $HTML $ZIP_DIR_NAME
  zip -r $ZIP_DIR_NAME.zip $ZIP_DIR_NAME/*
}

function make_zip_localized() {
# This creates a named zip that unpacks to the Project Version, localized to english
  version
  ZIP_DIR_NAME="$PROJECT-docs-$PROJECT_VERSION-$1"
  cd $SCRIPT_PATH/$BUILD
  mkdir $PROJECT_VERSION
  mv $HTML $PROJECT_VERSION/en
  # Add a redirect index.html file
  echo "$REDIRECT_EN_HTML" > $PROJECT_VERSION/index.html
  zip -r $ZIP_DIR_NAME.zip $PROJECT_VERSION/*
}

function build_all() {
  echo "Building GitHub Docs."
  ./build.sh build-github
  echo "Stashing GitHub Docs."
  cd $SCRIPT_PATH
  mkdir -p $SCRIPT_PATH/$BUILD_TEMP
  mv $SCRIPT_PATH/$BUILD/*.zip $SCRIPT_PATH/$BUILD_TEMP
  echo "Building Web Docs."
  ./build.sh build-web
  echo "Moving GitHub Docs."
  mv $SCRIPT_PATH/$BUILD_TEMP/*.zip $SCRIPT_PATH/$BUILD
  rm -rf $SCRIPT_PATH/$BUILD_TEMP
}

function build() {
  build_docs
  build_javadocs
  copy_javadocs
  make_zip
}

function check_includes() {
  if hash pandoc 2>/dev/null; then
    echo "Confirmed that pandoc is installed; checking the example README includes."
    # Build includes
    BUILD_INCLUDES_DIR=$SCRIPT_PATH/$BUILD/$INCLUDES
    rm -rf $BUILD_INCLUDES_DIR
    mkdir $BUILD_INCLUDES_DIR
    pandoc_includes $BUILD_INCLUDES_DIR
    # Test included files
    test_include hello-world.rst
    test_include sql-join-flow.rst
    test_include tigon-sql.rst
    test_include twitter-analytics.rst
  else
    echo "WARNING: pandoc not installed; checked-in README includes will be used instead."
  fi
}

function test_include() {
  BUILD_INCLUDES_DIR=$SCRIPT_PATH/$BUILD/$INCLUDES
  SOURCE_INCLUDES_DIR=$SCRIPT_PATH/$SOURCE/$EXAMPLES
  EXAMPLE=$1
  if diff -q $BUILD_INCLUDES_DIR/$1 $SOURCE_INCLUDES_DIR/$1 2>/dev/null; then
    echo "Tested $1; matches checked-in include file."
  else
    echo "WARNING: Tested $1; does not match checked-in include file. Copying to source directory."
    cp -f $BUILD_INCLUDES_DIR/$1 $SOURCE_INCLUDES_DIR/$1
  fi
}

function build_includes() {
  if hash pandoc 2>/dev/null; then
    echo "Confirmed that pandoc is installed; rebuilding the example README includes."
    SOURCE_INCLUDES_DIR=$SCRIPT_PATH/$SOURCE/$EXAMPLES
    rm -rf $SOURCE_INCLUDES_DIR
    mkdir $SOURCE_INCLUDES_DIR
    pandoc_includes $SOURCE_INCLUDES_DIR
  else
    echo "WARNING: pandoc not installed; checked-in README includes will be used instead."
  fi
}

function pandoc_includes() {
  # Uses pandoc to translate the README markdown files to rst in the target directory
  INCLUDES_DIR=$1
  pandoc -t rst $PROJECT_PATH/$TIGON_EXAMPLES/HelloWorld/README.md -o $INCLUDES_DIR/hello-world.rst
  pandoc -t rst $PROJECT_PATH/$TIGON_EXAMPLES/SQLJoinFlow/README.md -o $INCLUDES_DIR/sql-join-flow.rst
  pandoc -t rst $PROJECT_PATH/$TIGON_EXAMPLES/tigon-sql/README.md -o $INCLUDES_DIR/tigon-sql.rst
  pandoc -t rst $PROJECT_PATH/$TIGON_EXAMPLES/TwitterAnalytics/README.md -o $INCLUDES_DIR/twitter-analytics.rst

  # Fix version
  version_rewrite $SCRIPT_PATH/$SOURCE/getting-started.txt $INCLUDES_DIR/getting-started-versioned.rst

}

function version_rewrite() {
  version
  cd $SCRIPT_PATH
  echo "Re-writing $1 to $2"
  # Re-writes the version in an RST-snippet file to have the current version.
  REWRITE_SOURCE=$1
  REWRITE_TARGET=$2
  
  sed -e "s|<version>|$PROJECT_VERSION|g" $REWRITE_SOURCE > $REWRITE_TARGET
}

function build_quick() {
  build_docs
  copy_javadocs
}

function build_web() {
  build_docs_google $GOOGLE_ANALYTICS_WEB
  build_javadocs
  copy_javadocs
  make_zip_localized $WEB
}

function build_github() {
  build_docs_google $GOOGLE_ANALYTICS_GITHUB
  build_javadocs
  copy_javadocs
  make_zip_localized $GITHUB
}

function build_standalone() {
  cd $PROJECT_PATH
  mvn clean package -DskipTests -P examples && mvn package -pl standalone -am -DskipTests -P dist,release
}

function build_sdk() {
  build_standalone
}

function build_dependencies() {
  cd $PROJECT_PATH
  mvn clean package site -am -Pjavadocs -DskipTests
}

function version() {
  cd $PROJECT_PATH
#   PROJECT_VERSION=`mvn help:evaluate -o -Dexpression=project.version | grep -v '^\['`
  PROJECT_VERSION=`grep "<version>" pom.xml`
  PROJECT_VERSION=${PROJECT_VERSION#*<version>}
  PROJECT_VERSION=${PROJECT_VERSION%%</version>*}
  IFS=/ read -a branch <<< "`git rev-parse --abbrev-ref HEAD`"
  GIT_BRANCH="${branch[1]}"
}

function print_version() {
  version
  echo "PROJECT_PATH: $PROJECT_PATH"
  echo "PROJECT_VERSION: $PROJECT_VERSION"
  echo "GIT_BRANCH: $GIT_BRANCH"
}

function test() {
  echo "Test..."
  echo "Version..."
  print_version
  echo "Build all docs..."
  build
  echo "Build SDK..."
  build_sdk
  echo "Test completed."
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  all )                build_all; exit 1;;
  build )              build; exit 1;;
  build-includes )     build_includes; exit 1;;
  build-quick )        build_quick; exit 1;;
  build-github )       build_github; exit 1;;
  build-web )          build_web; exit 1;;
  check-includes )     check_includes; exit 1;;
  clean )              clean; exit 1;;
  docs )               build_docs; exit 1;;
  build-standalone )   build_standalone; exit 1;;
  copy-javadocs )      copy_javadocs; exit 1;;
  javadocs )           build_javadocs; exit 1;;
  depends )            build_dependencies; exit 1;;
  sdk )                build_sdk; exit 1;;
  version )            print_version; exit 1;;
  test )               test; exit 1;;
  zip )                make_zip; exit 1;;
  * )                  usage; exit 1;;
esac
