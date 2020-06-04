# Preface

In a perfect world every written service will work smooth, your test coverage is on top and there are no bugs in the implementation of your API. But we all know, that we can't achieve this world, sadly. It's not unusual that there's a bug and you have to debug this problem in a production environment. We have faced this problem with our go services in our Kubernetes cluster, and we want to show you how it's possible to remote debug a go service in a Kubernetes cluster.

## Software Prerequisites

For this case we create a kubernetes cluster running locally on our system. Therefore we need the following software:

* [Docker Desktop](https://docs.docker.com/get-docker) (used version: 19.03.8)
* [kind (Kubernetes in Docker)](https://kind.sigs.k8s.io) (used version: v0.7.0)
* [Kubectl](https://kubernetes.io/de/docs/tasks/tools/install-kubectl) (used version: 1.17.2)
* [Visual Studio Code](https://code.visualstudio.com/download) (used version: 1.32.3)

We decided to use `kind` instead of `minikube`, since it's a very good tool for testing Kubernetes locally, and we can use our docker images without a docker registry.

## Big Picture

First we will briefly explain how it works. We start by creating a new Kubernetes cluster `local-debug-k8s` on our local system.

* You need a docker container with [delve](https://github.com/go-delve/delve) (the go debugger) as the main process.
* The debugger delve needs access to the path with the project data. This is done by mounting `$GOPATH/src` on the pod which is running in the Kubernetes cluster.
* We start the delve container on port 30123 and bind this port to localhost, so that only our local debugger can communicate with delve.
* To debug an API with delve, it's necessary to set up an ingress network. For this we use port 8090.

A picture serves to illustrate the communication:

![Overview](images/big-picture.png "Big Picture")

### Creating a Kubernetes cluster

`kind` unfortunately doesn't use the environment variable `GOPATH`, so we have to update this in [config.yaml](cluster/config.yaml#L21):

```sh
sed -i.bak 's|'{GOPATH}'|'${GOPATH}'|g' cluster/config.yaml
```

You can also open [config.yaml](cluster/config.yaml#L21) and replace `{GOPATH}` with the absolute path manually. If you already installed kind (Kubernetes in Docker) on your local system, you can create the cluster with this command:

```sh
kind create cluster --config cluster/config.yaml --name=local-debug-k8s
```

Ensure that port 8090 and 30123 are not used on your local system. The newly created cluster has the name `local-debug-k8s` and has been created with custom configuration ( `--config cluster/config.yaml`). The following is a brief explanation:

```yml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches: # necessary, since we are going to install an ingress network in the cluster
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        authorization-mode: "AlwaysAllow"
  extraPortMappings:
  - containerPort: 80 # http endpoint of ingress runs on the port 80
    hostPort: 8090 # port on your host machine to call API's of the service
    protocol: TCP
  - containerPort: 30123 # node port for the delve server
    hostPort: 30123 # port on your host machine to communicate with the delve server
    protocol: TCP
- role: worker
  extraMounts:
    - hostPath: {GOPATH}/src # ATTENTION: you might want to replace this path with your ${GOPATH}/src manually
      containerPath: /go/src # path to the project folder inside the worker node
```

Expected result:

```sh
Creating cluster "local-debug-k8s" ...
✓ Ensuring node image (kindest/node:v1.17.0) 🖼
✓ Preparing nodes 📦 📦  
✓ Writing configuration 📜
✓ Starting control-plane 🕹️
✓ Installing CNI 🔌
✓ Installing StorageClass 💾
✓ Joining worker nodes 🚜

Set kubectl context to "kind-local-debug-k8s"
You can now use your cluster with:

kubectl cluster-info --context kind-local-debug-k8s

Have a nice day! 👋
```

Activate the kube-context for `kubectl` to communicate with the new cluster:

```sh
kubectl cluster-info --context kind-local-debug-k8s
```

#### Install nginx-ingress

For both ports (8090 and 30123) to work, it is necessary to deploy an nginx controller as an ingress controller:

```sh
kubectl create -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
```

Source: [kind documentation](https://kind.sigs.k8s.io/docs/user/ingress/#ingress-nginx>)

to observe the current status the following command can be executed:

```sh
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s
```

#### Labelling the node

We know that by default a kubernetes cluster will deploy a pod on a node which has enough ressources for this workload. Our docker image must be pulled on all nodes in our kubernetes cluster in order to be ready as quickly as possible. This process may take a long time. If the docker image isn't pulled on a node and a new pod will provisioned on this node, it will take more time to get ready and healthy.
For our use case we will label a node in our kubernetes cluster so that always this node will be used.

We label a node with _debug=true_:

```sh
kubectl label nodes local-debug-k8s-worker debug=true
```

### Creating a docker image

Our service has only one endpoint `/hello` and writes just a few logs. Let's checkout the Dockerfile for delve:

```Dockerfile
FROM golang:1.13-alpine

# compile gcc statically
ENV CGO_ENABLED=0
ENV GOROOT=/usr/local/go
# this path will be mounted in deploy-service.yaml
ENV GOPATH=${HOME}/go
ENV PATH=$PATH:${GOROOT}/bin

# Install git and get the latest version of delve via go
RUN apk update && apk add --no-cache \
    git && \
    go get github.com/go-delve/delve/cmd/dlv

# ATTENTION: you want to check, if the path to the project folder is the right one here
WORKDIR /go/src/github.com/setlog/debug-k8s

# 30123 for delve and 8090 for API calls
EXPOSE 30123 8090

# let's start delve as the entrypoint
ENTRYPOINT ["/go/bin/dlv", "debug", ".", "--listen=:30123", "--accept-multiclient", "--headless=true", "--api-version=2"]
```

So, let's build build our docker image from our [Dockerfile](Dockerfile):

```sh
docker build -t setlog/debug-k8s ./Dockerfile
```

After the build is done, we load the image `setlog/debug-k8s:latest` on the node _local-debug-k8s-worker_:

```sh
kind load docker-image setlog/debug-k8s:latest --name=local-debug-k8s --nodes=local-debug-k8s-worker
```

A message appears indicating that the docker image did not exist before:

```sh
    Image: "setlog/debug-k8s:latest" with ID "sha256:944baa03d49698b9ca1f22e1ce87b801a20ce5aa52ccfc648a6c82cf8708a783" not present on node "local-debug-k8s-worker"
```

### Deploy the delve container in our cluster

First of all we need a persistent volume and its claim in order to mount the project path into the node:

```sh
kubectl create -f cluster/persistent-volume.yaml
```

The interesting part here is:

```yaml
  hostPath:
    path: /go/src
```

Below is an image that shows the configurations through which our local path is mounted. In your environment it could be another path:

![Mounting](images/mounting.png "How to mount the project folder")

Check, if your persistent volume claim has been successfully created (STATUS must be Bound):

```sh
kubectl get pvc

    NAME     STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
    go-pvc   Bound    go-pv    256Mi      RWO            hostpath       51s
```

Now we are ready to deploy all our services in debug mode:

```sh
kubectl create -f cluster/deploy-service.yaml
```

Let's go through the pod manifest:

* _image_ is the previously built and loaded image into the kind cluster with `kind load image...`
* _imagePullPolicy_ must be set to _IfNotPresent_ because it's already loaded and we don't want Kubernetes to try it again

```yaml
      image: setlog/debug-k8s:latest
      imagePullPolicy: IfNotPresent
```

* We use the persistent volume claim to mount the project path into the pod, so that `/go/src` will be linked to `${GOPATH}/src` on your local system

```yaml
      containers:
        - name: debug-k8s
          ...
          volumeMounts:
            - mountPath: /go/src
              name: go-volume
      volumes:
        - name: go-volume
          persistentVolumeClaim:
            claimName: go-pvc
```

* As there might be several nodes in your kubernetes cluster, we deploy the pod on the node, that is labelled with _debug=true_. The docker image _setlog/debug-k8s_ was already loaded on this node.

```yaml
      nodeSelector:
        debug: "true"
```

* Service _service-debug_ has the type _NodePort_ and is mounted to the node. This port 30123 is equal to the parameter _--listen=:30123_ in the Dockerfile, which makes it possible to send debug commands to the delve server.

* Service _debug-k8s_ will be connected to the ingress server in the final step. It serves for exposing the API endpoints we are going to debug.

If you did all steps correctly, your pod should be up and running. Check it with `kubectl get pod`. You should see the output with the pod status _Running_ and two additional services _debug-k8s_ and _service-debug_:

```sh
NAME                            READY   STATUS    RESTARTS   AGE
pod/debug-k8s-6d69b65cf-4fl6t   1/1     Running   0          1h

NAME                    TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)           AGE
service/debug-k8s       ClusterIP   10.96.80.193   <none>        8090/TCP          1h
service/kubernetes      ClusterIP   10.96.0.1      <none>        443/TCP           1h
service/service-debug   NodePort    10.96.219.86   <none>        30123:30123/TCP   1h
```

_Hint: create a new variable to store the pod name using `PODNAME=$(kubectl get pod -o jsonpath='{.items[0].metadata.name}')`. It can be helpful, if you repeatedly debug the pod._

Usually it takes a couple of seconds to start the debugging process with delve. If your paths are mounted in the proper way, you will find the file `__debug_bin` in the project path on your computer. That is an executable which has been created by delve.

Also, you can output logs of the pod by performing `kubectl logs $PODNAME` in order to make sure the delve API server is listening at 30123.

Output:

```sh
        API server listening at: [::]:30123
```

_Hint: always wait until this log message is shown for this pod before you start the debugging process. Otherwise, the delve server is not up yet and cannot answer to the debugger._

### Starting the debug process via launch.json

Now we need a debug configuration in Visual Code. This can be done in `.vscode/launch.json`:

```json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Remote debug in Kubernetes",
            "type": "go",
            "request": "attach",
            "mode":"remote",
            "remotePath": "/go/src/github.com/setlog/debug-k8s",
            "port": 30123,
            "host": "127.0.0.1",
            "showLog": true
        }
    ]
}
```

Where `remotePath` is the path to the project path inside the pod, `port` the local port to send the debug commands to, and `host` the host to send the debug commands to.

You find the new configuration in Visual Code here:

![Debug Configuration](images/debug-config.png "Where to find the debug config")

After starting the debug process there is a new log created by the go service:

    2020/05/28 15:38:53 I am going to start...

We are ready to debug, but we have to trigger the API functions through the ingress service. Deploy it with kubectl:

```sh
kubectl create -f cluster/ingress.yaml
```

And try accessing it now:

```sh
curl http://localhost:8090/hello
```

Which should trigger the debugger:

![Breakpoint](images/debug-screen.png "Breakpoint in Visual Code")

Happy debugging!

### Cleaning up

If you don't need your kind cluster anymore, it can be removed with following command:

```sh
kind delete cluster --name=local-debug-k8s
```
