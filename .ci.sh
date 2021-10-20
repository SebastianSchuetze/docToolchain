#!/bin/bash

set -o errtrace -o nounset -o pipefail -o errexit

# Enable build on Travis as well as on GH Actions
set +u
if test "${GITHUB_WORKFLOW}"; then
    BRANCH=${GITHUB_REF##*/}
    BUILD_DIR=${GITHUB_WORKSPACE}
    BUILD_NUMBER="${GITHUB_WORKFLOW}-${GITHUB_RUN_ID}-${GITHUB_RUN_NUMBER}"
    CI_SERVER="Github"
    PULL_REQUEST=$(test "${GITHUB_HEAD_REF}" && echo "true" || echo "false")
    # JDK_VERSION is set by GH Action
    # RUNNER_OS is set by GH Action
elif test "${TRAVIS_BRANCH}"; then
    BRANCH=${TRAVIS_BRANCH}
    BUILD_NUMBER=${TRAVIS_BUILD_NUMBER}
    BUILD_DIR=${TRAVIS_BUILD_DIR}
    CI_SERVER="Travis"
    PULL_REQUEST=${TRAVIS_PULL_REQUEST:-"false"}
    JDK_VERSION=${TRAVIS_JDK_VERSION}
    RUNNER_OS="ubuntu-latest"
else
    echo "Cannot determine CI Server (Travis or Github)" >&2
    exit 1
fi
set -u

# Goto directory of this script
cd "$(dirname "${BASH_SOURCE[0]}")"

cleaning () {
  echo "############################################"
  echo "#                                          #"
  echo "#        Cleaning                          #"
  echo "#                                          #"
  echo "############################################"
  ./gradlew clean
}

dependency_info() {
  echo "############################################"
  echo "#                                          #"
  echo "#        Check for dependency updates      #"
  echo "#                                          #"
  echo "############################################"
  ./gradlew -b init.gradle dependencyUpdates
  ./gradlew dependencyUpdates
}

unit_tests () {
  echo "############################################"
  echo "#                                          #"
  echo "#        Unit testing                      #"
  echo "#                                          #"
  echo "############################################"
  if [ "${BRANCH}" == "ng" ] || [ "${BRANCH}" == "main-2.x" ] ; then
    echo "skipping tests for now"
  else
    ./gradlew test --info
  fi
}

integration_tests () {
  echo "############################################"
  echo "#                                          #"
  echo "#        Integration testing               #"
  echo "#                                          #"
  echo "############################################"
  if [ "${BRANCH}" == "ng" ] || [ "${BRANCH}" == "main-2.x" ] ; then
    echo "skipping tests for now"
  else
      TEMPLATES='Arc42DE Arc42EN Arc42ES'
      for TEMPLATE in ${TEMPLATES}; do
        echo "### ${TEMPLATE}"
        TEST_DIR="build/${TEMPLATE}_test"

        ./gradlew -b init.gradle "init${TEMPLATE}" -PnewDocDir="${TEST_DIR}"
        ./bin/doctoolchain "${TEST_DIR}" generatePDF
        ./bin/doctoolchain "${TEST_DIR}" generateHTML
        # ./bin/doctoolchain "${TEST_DIR}" publishToConfluence

        echo "#### check for html result"
        # if [ ! -f "${TEST_DIR}"/build/html5/arc42-template.html ]; then exit 1; fi
        echo "#### check for pdf result"
        # if [ ! -f "${TEST_DIR}"/build/pdf/arc42-template.pdf ]; then exit 1; fi
      done
  fi
}

check_for_clean_worktree() {
  echo "############################################"
  echo "#                                          #"
  echo "#        Check for clean worktree          #"
  echo "#                                          #"
  echo "############################################"
  # To be executed as latest possible step, to ensures that there is no
  # uncommitted code and there are no untracked files, which means .gitignore is
  # complete and all code is part of a reviewable commit.
  GIT_STATUS="$(git status --porcelain)"
  if [[ ${GIT_STATUS} ]]; then
    echo "Your worktree is not clean, there is either uncommitted code or there are untracked files:"
    echo "${GIT_STATUS}"
    exit 1
  fi
}

create_doc () {
  echo "############################################"
  echo "#                                          #"
  echo "#        Create documentation              #"
  echo "#                                          #"
  echo "############################################"
  echo "TRAVIS_BRANCH=${BRANCH}"
  if [ "${BRANCH}" == "ng" ] || [ "${BRANCH}" == "main-2.x" ] ; then
    echo ">>> exportMarkdown"
    ./dtcw local exportMarkdown
    echo ">>> exportChangelog"
    ./dtcw local exportChangeLog
    echo ">>> exportContributors"
    ./dtcw local exportContributors
    echo ">>> generateSite"
    ./dtcw local generateSite --stacktrace
    [ -d docs ] || mkdir docs
    cp -r build/microsite/output/. docs/.
#    [ -d  docs/htmlchecks ] || mkdir docs/htmlchecks
#    cp -r build/docs/report/htmlchecks/. docs/htmlchecks/.

  else
    ./gradlew exportMarkdown exportChangeLog exportContributors generateHTML htmlSanityCheck --stacktrace && ./copyDocs.sh
  fi
}

publish_doc () {
  echo "publish_doc"
  echo "${PULL_REQUEST} | ${JDK_VERSION} | ${BRANCH}"
  # Take from and modified http://sleepycoders.blogspot.de/2013/03/sharing-travis-ci-generated-files.html
  # ensure publishing doesn't run on pull requests, only when token is available and only on JDK11 matrix build and on master or a travisci test branch
  if [ "${PULL_REQUEST}" == "false" ] && [ -n "${GH_TOKEN}" ] && { [ "${JDK_VERSION}" == "adopt-11" ] || [ "${JDK_VERSION}" == "openjdk11" ] || { [ "${JDK_VERSION}" == "11-adopt" ] && [ "${RUNNER_OS}" == "ubuntu-latest" ]; }; } && { [ "${BRANCH}" == "travisci" ] || [ "${BRANCH}" == "master" ] || [ "${BRANCH}" == "ng" ] || [ "${BRANCH}" == "main-1.x" ] || [ "${BRANCH}" == "main-2.x" ]; } ; then
    echo "############################################"
    echo "#                                          #"
    echo "#        Publish documentation             #"
    echo "#                                          #"
    echo "############################################"
    echo -e "Starting to update gh-pages\n"

    #go to home and setup git
    cd "${HOME}"
    git config --global user.email "travis@travis-ci.org"
    git config --global user.name "Travis"

    #using token clone gh-pages branch
    git clone --quiet --branch=gh-pages "https://${GH_TOKEN}@github.com/${TRAVIS_REPO_SLUG}.git" gh-pages > /dev/null

    if [ "${BRANCH}" == "master" ] || [ "${BRANCH}" == "main-1.x" ] ; then
      #go into directory and copy data we're interested in to that directory
      cd gh-pages
      rm -rf v1.3.x/*
      cp -Rf "${BUILD_DIR}"/docs/* v1.3.x/.
    fi
    if [ "${BRANCH}" == "ng" ] || [ "${BRANCH}" == "main-2.x" ] ; then
      #go into directory and copy data we're interested in to that directory
      cd gh-pages
      rm -rf v2.0.x/*
      cp -Rf "${BUILD_DIR}"/build/microsite/output/* v2.0.x/.
    fi

    #add, commit and push files
    git add -f .
    git commit -m "${CI_SERVER} build '${BUILD_NUMBER}' pushed to gh-pages"
    git push -fq origin gh-pages > /dev/null

    echo -e "Done publishing to gh-pages.\n"
  fi
}

cleaning
dependency_info
#unit_tests
#integration_tests
check_for_clean_worktree
create_doc
publish_doc
