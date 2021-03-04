#!/usr/bin/env python3
import argparse
import urllib.request
import urllib.parse
import urllib.error
import json
import time
import os


def second_to_time_string(sec):
    seconds = int(sec)
    days = seconds // 86400
    seconds %= 86400
    hours = seconds // 3600
    seconds %= 3600
    minutes = seconds // 60
    seconds %= 60
    str = '{:02d}:{:02d}:{:02d}'.format(hours, minutes, seconds)
    if days:
        str += '{:d} days '.format(days) + str
    return str


def parse_args():
    # construct the argument parse and parse the arguments
    parser = argparse.ArgumentParser()
    parser.add_argument('url', help='the url address of YARS service')
    parser.add_argument('type', help='type of test line')
    parser.add_argument('action', help='action to do, "reserve" to reserve one test line, "release" to release one test line')
    parser.add_argument('uuid', help='uuid to identify current session')
    parser.add_argument('-u', '--user', help='user name')
    parser.add_argument('-t', '--time', help='time needed', type=int)
    return parser.parse_args()


def reserve_env(url, type, uuid, username, reqtime: int):
    api_url = '{:s}/{:s}/{:s}'.format(url, type, uuid)
    if not username or not reqtime:
        print('error: USER and TIME are required: for reservation.')
        exit(1)
    # add current request to queue
    print('Sending reserve request to YARS...', flush=True)
    try:
        req_body = urllib.parse.urlencode({'username': username, 'time': reqtime}).encode('utf-8')
        req = urllib.request.Request(api_url, req_body, method='POST')
        res = urllib.request.urlopen(req, timeout=30)
        res_body = json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_respons_data = e.read().decode("utf-8")
        try:
            res_body = json.loads(error_respons_data)
            print('YARS: Create new session failed with return code {:d} ({:s}): {:s}'.format(
                e.status, e.reason, res_body['error']))
        except:
            print('YARS: HTTP request failed with:\n{:s}\n'.format(error_respons_data))
        exit(1)
    # wait and get env
    last_msg_len = 0
    while True:
        try:
            req = urllib.request.Request(api_url, method='GET')
            res = urllib.request.urlopen(req, timeout=30)
            res_body = json.loads(res.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            error_respons_data = e.read().decode("utf-8")
            try:
                res_body = json.loads(error_respons_data)
                print('YARS: Get session state failed with return code {:d} ({:s}): {:s}'.format(
                    e.status, e.reason, res_body['error']))
            except:
                print('YARS: HTTP request failed with:\n{:s}\n'.format(error_respons_data))
            exit(1)
        state = res_body['state']
        if state == 'queuing':
            msg = 'Queued {:d} out of {:d}. Next env will release in {:s}.'.format(
                int(res_body['position']),
                int(res_body['queue_length']),
                second_to_time_string(res_body['next_free_in'])
            )
            print(' ' * last_msg_len, end='\r', flush=False)
            print(msg, end='\r', flush=True)
            last_msg_len = len(msg)
        elif state == 'running':
            with open('yars-device.address', 'w') as f:
                f.write(res_body['device'])
            print('Successfully reserved one env {:s}.'.format(res_body['device']))
            break
        else:
            print('YARS: Unknown session state: {:s}'.format(state))
            exit(1)
        time.sleep(5)


def release_env(url, type, uuid):
    api_url = '{:s}/{:s}/{:s}'.format(url, type, uuid)
    print('Sending release request to YARS...', flush=True)
    try:
        req = urllib.request.Request(api_url, method='DELETE')
        res = urllib.request.urlopen(req, timeout=30)
        res_body = json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_respons_data = e.read().decode("utf-8")
        try:
            res_body = json.loads(error_respons_data)
            print('YARS: Delete session failed with return code {:d} ({:s}): {:s}'.format(
                e.status, e.reason, res_body['error']))
        except:
            print('YARS: HTTP request failed with:\n{:s}\n'.format(error_respons_data))
        exit(1)
    print('Env released successfully.')
    try:
        os.remove('yars-device.address')
    except:
        pass


def main():
    args = parse_args()
    if args.action == 'reserve':
        reserve_env(args.url, args.type, args.uuid, args.user, args.time)
    elif args.action == 'release':
        release_env(args.url, args.type, args.uuid)
    else:
        print('error: Unsupported action {:s}.'.format(args.action))
        exit(1)


if __name__ == '__main__':
    main()
