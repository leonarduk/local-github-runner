// Provisions and manages the self-hosted GitHub Actions runner pool for
// leonarduk/spring-professional-udemy-practice-tests.
//
// Chain of custody: Jenkins -> runner containers -> GitHub Actions -> the
// repo's own checks. Jenkins does not run validate.py itself here; it keeps
// runners alive so that .github/workflows/ci.yml has somewhere to execute.
// (allotmint's own Jenkinsfile takes the other approach -- mirroring the
// GitHub Actions checks directly -- which remains the simpler option if the
// GitHub Actions hop ever stops earning its keep.)
//
// Why this exists at all: this repo is private and its Actions minutes are
// exhausted, so every hosted run fails in seconds with no logs. See
// runner/README.md.
//
// SETUP, once, on the Jenkins instance:
//   1. Credential 'GITHUB_RUNNER_PAT', Secret text: a PAT that can register
//      runners on this repo -- fine-grained with Administration: read &
//      write, or classic with `repo`. NOT the same token as GITHUB_TOKEN
//      used for PR comments; this one is strictly more privileged.
//   2. The Jenkins node needs the Docker CLI and a reachable Docker socket.
//      The allotmint-jenkins image already has both.
//   3. Pipeline job, "Pipeline script from SCM", Script Path
//      runner/Jenkinsfile.

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
               description: 'How many runners to keep available. Each serves one job then exits and is replaced. 2 is enough to stop the two ci.yml jobs queueing behind each other.')
        string(name: 'RUNNER_HOST_LABEL', defaultValue: 'bedroom',
               description: 'Names the machine this pool runs on. Becomes a runner label and the runner-name prefix, so the GitHub runner list says which box a runner is on.')
        string(name: 'GITHUB_REPOSITORY', defaultValue: 'leonarduk/spring-professional-udemy-practice-tests',
               description: 'Repository the runners register against.')
        booleanParam(name: 'REBUILD_IMAGE', defaultValue: false,
                     description: 'Force `docker compose build --no-cache`. Needed after bumping RUNNER_VERSION in the Dockerfile, since the download layer is otherwise cached.')
    }

    environment {
        COMPOSE_DIR = 'runner'
        // Outside the workspace on purpose. Compose bind-mounts this file
        // into each container and re-reads it on every restart -- and these
        // containers restart constantly, one per job -- so it has to
        // survive workspace cleanup and the end of this build.
        PAT_DIR     = '/var/lib/jenkins/gh-runner'
        PAT_FILE    = '/var/lib/jenkins/gh-runner/pat.secret'
        // Must match `image:` in compose.yaml. Verify borrows this image's
        // jq, since the Jenkins node has neither jq nor python3.
        RUNNER_IMAGE = 'local-github-runner:local'
    }

    stages {

        stage('Preflight') {
            steps {
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
