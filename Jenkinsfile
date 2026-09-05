// UNVERIFIED. This pipeline has never been run end to end. Every pool in
// service was created by hand with `docker compose`; that is the tested path
// and README.md documents it. Read this as a sketch of the right shape, not
// as something known to work, and expect to debug it on first use. Do not
// reach for it during an outage.
//
// Provisions and manages a pool of self-hosted GitHub Actions runners for
// one repository, named by the GITHUB_REPOSITORY parameter.
//
// Chain of custody: Jenkins -> runner containers -> GitHub Actions -> the
// target repo's own checks. Jenkins does not run those checks itself; it
// keeps runners alive so that the repo's workflows have somewhere to
// execute. (Mirroring a repo's checks in Jenkins directly remains the
// simpler option wherever the GitHub Actions hop stops earning its keep.)
//
// One job per pool. Point a second job at a second GITHUB_REPOSITORY and the
// two coexist: COMPOSE_PROJECT is derived from the repository below, and
// that name is what keeps their containers apart.
//
// SETUP, once, on the Jenkins instance:
//   1. Credential 'GITHUB_RUNNER_PAT', Secret text: a PAT that can register
//      runners on the target repo -- fine-grained with Administration: read
//      & write, or classic with `repo`. NOT the same token as a GITHUB_TOKEN
//      used for PR comments; this one is strictly more privileged. A PAT
//      covering several repos lets one credential serve several pools.
//   2. The Jenkins node needs the Docker CLI and a reachable Docker socket.
//      The allotmint-jenkins image already has both.
//   3. Pipeline job, "Pipeline script from SCM", pointing at this repo,
//      Script Path `Jenkinsfile`.

pipeline {
    agent any

    options {
        // The pool is a singleton: two builds racing `compose up` on the
        // same project name would fight over the same containers.
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        choice(name: 'ACTION',
               choices: ['up', 'status', 'restart', 'down'],
               description: '''up = build the image and bring the pool to RUNNER_COUNT (safe to re-run; this is the default).
status = report what is running and what GitHub sees, change nothing.
restart = recreate the containers, e.g. after editing compose.yaml.
down = stop the pool and deregister every runner.''')
        string(name: 'RUNNER_COUNT', defaultValue: '2',
               description: 'How many runners to keep available. Each serves one job then exits and is replaced. Size it to the number of jobs in the target repo's workflows that could run at once, or they queue behind each other.')
        string(name: 'RUNNER_HOST_LABEL', defaultValue: 'bedroom',
               description: 'Names the machine this pool runs on. Becomes a runner label and the runner-name prefix, so the GitHub runner list says which box a runner is on.')
        string(name: 'GITHUB_REPOSITORY', defaultValue: '',
               description: 'Repository the runners register against, as owner/repo. Required. Also derives the compose project name, so two jobs with different values manage separate pools.')
        booleanParam(name: 'REBUILD_IMAGE', defaultValue: false,
                     description: 'Force `docker compose build --no-cache`. Needed after bumping RUNNER_VERSION in the Dockerfile, since the download layer is otherwise cached.')
    }

    environment {
        // This repo is the compose context, so the pipeline runs from the
        // checkout root rather than a subdirectory.
        COMPOSE_DIR = '.'
        // The pool's identity, derived from the repository it serves. The
        // compose project name is the ONLY thing separating one pool from
        // another on a host -- share it between two repos and the second
        // `up` reconfigures the first one's containers instead of adding
        // its own. Deriving it here is what lets one Jenkins instance run a
        // pool per repo without them colliding.
        //
        // Repo name only, not owner/repo, matching the pools already running
        // by hand. Two repos of the same name under different owners would
        // collide; name the job accordingly if that ever comes up.
        // split rather than tokenize: this is evaluated before any stage
        // runs, so an empty parameter here must yield an empty string, not
        // throw out of the environment block ahead of Preflight's message.
        // ''.split('/') is [''], where ''.tokenize('/') is [] and .last()
        // on it raises NoSuchElementException.
        POOL_NAME   = "${(params.GITHUB_REPOSITORY ?: '').split('/').last().toLowerCase().replaceAll(/[^a-z0-9_-]/, '-')}"
        COMPOSE_PROJECT_NAME = "gh-runner-${POOL_NAME}"
        // Outside the workspace on purpose. Compose bind-mounts this file
        // into each container and re-reads it on every restart -- and these
        // containers restart constantly, one per job -- so it has to
        // survive workspace cleanup and the end of this build.
        //
        // Per pool, so that pools serving different repos can hold PATs with
        // different scopes, and revoking one does not silently break the
        // others at their next container restart.
        PAT_DIR     = "/var/lib/jenkins/gh-runner/${POOL_NAME}"
        PAT_FILE    = "/var/lib/jenkins/gh-runner/${POOL_NAME}/pat.secret"
        // Must match `image:` in compose.yaml. Verify borrows this image's
        // jq, since the Jenkins node has neither jq nor python3.
        RUNNER_IMAGE = 'local-github-runner:local'
    }

    stages {

        stage('Preflight') {
            steps {
                script {
                    // Fail here with a sentence rather than deep inside
                    // compose, which reports it as an interpolation error
                    // against a variable the operator never typed.
                    if (!params.GITHUB_REPOSITORY?.trim()) {
                        error('GITHUB_REPOSITORY is required: the repository these runners register against, as owner/repo.')
                    }
                    echo "pool ${env.COMPOSE_PROJECT_NAME} -> ${params.GITHUB_REPOSITORY} on ${params.RUNNER_HOST_LABEL}"
                }
                sh '''
                    set -eu
                    echo "--- docker ---"
                    docker version --format '{{.Server.Version}}' \
                        || { echo "ERROR: no reachable Docker daemon from this Jenkins node." >&2
                             echo "The node needs the Docker CLI and a mounted /var/run/docker.sock." >&2
                             exit 1; }
                    docker compose version --short
                '''
            }
        }

        stage('Write PAT') {
            when { expression { params.ACTION in ['up', 'restart'] } }
            steps {
                // withCredentials masks the value in the console log. `set +x`
                // stops the shell tracing the line that writes it, which
                // masking alone would not save us from in a `sh -x` build.
                withCredentials([string(credentialsId: 'GITHUB_RUNNER_PAT',
                                        variable: 'GH_RUNNER_PAT')]) {
                    sh '''
                        set +x
                        set -eu
                        mkdir -p "$PAT_DIR"
                        chmod 700 "$PAT_DIR"
                        umask 077
                        printf '%s' "$GH_RUNNER_PAT" > "$PAT_FILE"
                        chmod 600 "$PAT_FILE"
                        echo "PAT written to $PAT_FILE ($(wc -c < "$PAT_FILE") bytes)"
                    '''
                }
            }
        }

        stage('Build image') {
            when {
                expression { params.ACTION in ['up', 'restart'] }
            }
            steps {
                dir("${env.COMPOSE_DIR}") {
                    script {
                        def noCache = params.REBUILD_IMAGE ? '--no-cache --pull' : ''
                        sh """
                            set -eu
                            docker compose build ${noCache}
                        """
                    }
                }
            }
        }

        stage('Apply') {
            steps {
                dir("${env.COMPOSE_DIR}") {
                    script {
                        // Passed through the environment rather than written
                        // to a .env file, so nothing this build creates is
                        // left lying in the workspace.
                        withEnv([
                            "RUNNER_PAT_FILE=${env.PAT_FILE}",
                            "RUNNER_HOST_LABEL=${params.RUNNER_HOST_LABEL}",
                            "GITHUB_REPOSITORY=${params.GITHUB_REPOSITORY}",
                        ]) {
                            if (params.ACTION == 'down') {
                                // Each container deregisters its own runner
                                // on SIGTERM. The generous timeout is so a
                                // runner mid-job can finish rather than be
                                // killed and left dangling as offline.
                                sh 'docker compose down --timeout 120'
                            } else if (params.ACTION == 'restart') {
                                sh """
                                    set -eu
                                    docker compose down --timeout 120
                                    docker compose up -d --scale runner=${params.RUNNER_COUNT}
                                """
                            } else if (params.ACTION == 'up') {
                                // Idempotent: re-running converges the pool
                                // on RUNNER_COUNT without disturbing any
                                // container that is currently running a job.
                                sh """
                                    set -eu
                                    docker compose up -d --scale runner=${params.RUNNER_COUNT}
                                """
                            } else {
                                sh 'docker compose ps'
                            }
                        }
                    }
                }
            }
        }

        stage('Verify') {
            when { expression { params.ACTION != 'down' } }
            steps {
                // Parameters go through the environment rather than being
                // spliced into the script text: a Groovy-interpolated
                // parameter is shell-injectable and unreadable besides.
                withEnv(["WANT=${params.RUNNER_COUNT}",
                         "REPO=${params.GITHUB_REPOSITORY}",
                         "HOST_LABEL=${params.RUNNER_HOST_LABEL}"]) {
                    withCredentials([string(credentialsId: 'GITHUB_RUNNER_PAT',
                                            variable: 'GH_RUNNER_PAT')]) {
                        // This Jenkins image has curl and git but no jq and
                        // no python3, so the JSON is parsed inside the runner
                        // image, which ships jq for its own entrypoint. That
                        // keeps the parsing honest without adding a
                        // dependency to the Jenkins node or assuming a
                        // pipeline plugin is installed.
                        sh '''
                            set +x
                            set -eu

                            if ! docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1; then
                                echo "NOTE: $RUNNER_IMAGE is not built on this node, so the"
                                echo "      runner list cannot be parsed. Re-run with ACTION=up."
                                exit 0
                            fi

                            # --entrypoint is required: the image's entrypoint
                            # is the runner registration script, so without
                            # this the jq arguments are handed to that
                            # instead and it exits complaining about
                            # GITHUB_REPOSITORY.
                            jq_in_container() {
                                docker run --rm -i --entrypoint jq "$RUNNER_IMAGE" "$@"
                            }

                            online=0
                            for attempt in $(seq 1 20); do
                                if ! body="$(curl -fsS \
                                        -H "Authorization: Bearer $GH_RUNNER_PAT" \
                                        -H "Accept: application/vnd.github+json" \
                                        -H "X-GitHub-Api-Version: 2022-11-28" \
                                        "https://api.github.com/repos/${REPO}/actions/runners")"; then
                                    echo "ERROR: could not query the runner list for ${REPO}." >&2
                                    echo "       Check that GITHUB_RUNNER_PAT has Administration: read & write." >&2
                                    exit 1
                                fi
                                online="$(printf '%s' "$body" | jq_in_container -r \
                                    --arg label "$HOST_LABEL" \
                                    '[.runners[]
                                      | select(.status == "online")
                                      | select([.labels[].name] | index($label))]
                                     | length')"
                                echo "attempt ${attempt}: ${online}/${WANT} runner(s) online with label '${HOST_LABEL}'"
                                if [ "$online" -ge "$WANT" ]; then
                                    break
                                fi
                                sleep 5
                            done

                            echo "--- runners registered on ${REPO} ---"
                            printf '%s' "$body" | jq_in_container -r \
                                '.runners[]
                                 | "  \\(.name)  \\(.status)  busy=\\(.busy)  [\\([.labels[].name] | join(","))]"'

                            if [ "$online" -lt "$WANT" ]; then
                                echo "ERROR: only ${online} of ${WANT} runners came online." >&2
                                exit 1
                            fi
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            dir("${env.COMPOSE_DIR}") {
                withEnv(["RUNNER_PAT_FILE=${env.PAT_FILE}",
                         "RUNNER_HOST_LABEL=${params.RUNNER_HOST_LABEL}",
                         "GITHUB_REPOSITORY=${params.GITHUB_REPOSITORY}"]) {
                    // Best-effort diagnostics: never turn a reporting
                    // problem into a build failure.
                    sh '''
                        set +e
                        echo "--- containers ---"
                        docker compose ps
                        echo "--- recent runner output ---"
                        docker compose logs --tail 40 --no-color
                        exit 0
                    '''
                }
            }
        }
        failure {
            echo '''Pool did not reach the requested size.

Most common causes, in order:
  - GITHUB_RUNNER_PAT lacks Administration: read & write (or `repo`), so the
    container could not mint a registration token. The container log shows
    "could not mint a registration token".
  - The Jenkins node cannot reach api.github.com.
  - The image is stale after a RUNNER_VERSION bump -- re-run with
    REBUILD_IMAGE=true.

Nothing is left half-applied: re-running with ACTION=up is safe.'''
        }
    }
}
