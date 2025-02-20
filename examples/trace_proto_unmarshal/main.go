package main

import (
	"fmt"

	"github.com/golang/protobuf/proto"
	"trace_proto_unmarshal/pb"
)

func main() {
	msg := &pb.HelloRequest{
		Msg: "hello world",
	}
	data, err := proto.Marshal(msg)
	if err != nil {
		panic(err)
	}

	msg2 := &pb.HelloRequest{}
	err = proto.Unmarshal(data, msg2)
	if err != nil {
		panic(err)
	}
	fmt.Println("len(data):", len(data))
}
