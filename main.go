package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func hello(w http.ResponseWriter, req *http.Request) {
	fmt.Fprintf(w, "Hostname: "+os.Getenv("HOSTNAME")+"\n")
}

func main() {
	http.HandleFunc("/hello", hello)
	log.Println("I am going to start...")
	if err := http.ListenAndServe(":http", nil); err != nil {
		panic(err)
	}
}
