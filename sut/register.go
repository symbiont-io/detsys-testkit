package sut

import (
	"fmt"
	"log"
	"strconv"
	"time"

	"github.com/symbiont-io/detsys/lib"
)

type SessionId struct {
	Id int `json:"id"`
}

func (sid SessionId) MarshalText() ([]byte, error) {
	return []byte(strconv.Itoa(sid.Id)), nil
}

type Register struct {
	Value []int `json:"value"`
}

func NewRegister() *Register {
	return &Register{
		Value: []int{},
	}
}

type Read struct {
}

func (_ Read) Request() {}

type Write struct {
	Value int `json:"value"`
}

func (_ Write) Request() {}

type Value struct {
	Value []int `json:"value"`
}

func (_ Value) Response() {}

type Ack struct {
}

func (_ Ack) Response() {}

type InternalRequest struct {
	Id      SessionId   `json:"id"`
	Request lib.Request `json:"request"`
}

func (_ InternalRequest) Message() {}

type InternalResponse struct {
	Id       SessionId    `json:"id"`
	Response lib.Response `json:"response"`
}

func (_ InternalResponse) Message() {}

func (r *Register) Receive(_ time.Time, from string, event lib.InEvent) []lib.OutEvent {
	var oevs []lib.OutEvent
	switch ev := event.(type) {
	case *lib.InternalMessage:
		switch msg := (*ev).Message.(type) {
		case InternalRequest:
			switch imsg := msg.Request.(type) {
			case Read:
				oevs = []lib.OutEvent{
					{
						To: from,
						Args: &lib.InternalMessage{InternalResponse{
							Id:       msg.Id,
							Response: Value{r.Value},
						}},
					},
				}
			case Write:
				r.Value = append(r.Value, imsg.Value)
				oevs = []lib.OutEvent{
					{
						To: from,
						Args: &lib.InternalMessage{InternalResponse{
							Id:       msg.Id,
							Response: Ack{},
						}},
					},
				}
			default:
				log.Fatalf("Received unknown message: %#v\n", msg)
				return nil

			}
		default:
			log.Fatalf("Received unknown event: %#v\n", msg)
			return nil
		}
	default:
		log.Fatalf("Received unknown event: %#v\n", ev)
		return nil
	}
	return oevs
}

func (r *Register) Tick(_ time.Time) []lib.OutEvent {
	return nil
}

var _ lib.InEvent = lib.ClientRequest{1, Write{2}}
var _ lib.Args = lib.ClientResponse{1, Ack{}}
var _ lib.InEvent = lib.ClientRequest{1, Read{}}
var _ lib.Args = lib.ClientResponse{1, Value{[]int{2}}}

var _ lib.InEvent = lib.InternalMessage{InternalRequest{SessionId{0}, Write{2}}}
var _ lib.Args = lib.InternalMessage{InternalResponse{SessionId{0}, Ack{}}}
var _ lib.InEvent = lib.InternalMessage{InternalRequest{SessionId{0}, Read{}}}
var _ lib.Args = lib.InternalMessage{InternalResponse{SessionId{0}, Value{[]int{2}}}}
var _ lib.Reactor = &Register{}

// ---------------------------------------------------------------------

type FrontEnd struct {
	InFlight                map[uint64]SessionId `json:"inFlight"`
	InFlightSessionToClient map[SessionId]uint64 `json:"inFlightSessionToClient"`
	NextSessionId           int                  `json:"nextSessionId"`
}

func NewFrontEnd() *FrontEnd {
	return &FrontEnd{map[uint64]SessionId{}, map[SessionId]uint64{}, 0}
}

const register1 string = "register1"
const register2 string = "register2"

func (fe *FrontEnd) NewSessionId(clientId uint64) (SessionId, error) {
	var sessionId SessionId
	_, ok := fe.InFlight[clientId]

	if ok {
		return sessionId, fmt.Errorf("Client %d already has a session", clientId)
	}

	sessionId.Id = fe.NextSessionId
	fe.NextSessionId++
	fe.InFlight[clientId] = sessionId
	fe.InFlightSessionToClient[sessionId] = clientId

	return sessionId, nil
}

func (fe *FrontEnd) RemoveSession(sessionId SessionId) (uint64, bool) {
	clientId, ok := fe.InFlightSessionToClient[sessionId]

	if ok {
		delete(fe.InFlight, clientId)
		delete(fe.InFlightSessionToClient, sessionId)
	}

	return clientId, ok
}

func translate(req lib.Request, sessionId SessionId) *lib.InternalMessage {
	return &lib.InternalMessage{
		Message: InternalRequest{
			Id:      sessionId,
			Request: req,
		},
	}
}

func (fe *FrontEnd) ReceiveClient(at time.Time, from string, event lib.ClientRequest) []lib.OutEvent {
	var oevs []lib.OutEvent
	sessionId, err := fe.NewSessionId(event.Id)

	if err != nil {
		// maybe not fatal?
		log.Fatal(err)
		return nil
	}

	oevs = []lib.OutEvent{
		{
			To:   register1,
			Args: translate(event.Request, sessionId),
		},
		{
			To:   register2,
			Args: translate(event.Request, sessionId),
		},
	}

	// we should also add ack if this was a write, and if so also add an ack..

	return oevs
}

func (fe *FrontEnd) Receive(at time.Time, from string, event lib.InEvent) []lib.OutEvent {
	var oevs []lib.OutEvent
	switch ev := event.(type) {
	case *lib.ClientRequest:
		oevs = fe.ReceiveClient(at, from, *ev)
	case *lib.InternalMessage:
		switch msg := (*ev).Message.(type) {
		case InternalResponse:
			clientId, ok := fe.RemoveSession(msg.Id)
			if ok {
				oevs = []lib.OutEvent{
					{
						To: fmt.Sprintf("client:%d", clientId),
						Args: &lib.ClientResponse{
							Id:       clientId,
							Response: msg.Response,
						},
					},
				}
			}
		default:
			log.Fatalf("Received unknown message: %+v\n", msg)
			return nil
		}
	default:
		log.Fatalf("Received unknown message: %#v\n", ev)
		return nil
	}
	return oevs
}

func (_ *FrontEnd) Tick(_ time.Time) []lib.OutEvent {
	return nil
}
