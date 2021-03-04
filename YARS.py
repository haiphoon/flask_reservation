#!/usr/bin/env python3
import time
import datetime
from flask import Flask
from flask_restful import Api, Resource, reqparse

env_list = [
    {
        'device': '5gRobot184.srnhz.nsn-rdnet.net',
        'type': '5G_MASTER_ASOD',
        'location': 'hz'
    },
    {
        'device': '5gRobot180.srnhz.nsn-rdnet.net',
        'type': '5G_MASTER_RCP',
        'location': 'hz'
    },
    {
        'device': '5gRobot181.srnhz.nsn-rdnet.net',
        'type': '5G_MASTER_RCP_ASIK_MMX',
        'location': 'hz'
    },
    {
        'device': '5gRobot182.srnhz.nsn-rdnet.net',
        'type': '5G_MASTER_ASIK_XHH',
        'location': 'hz'
    },
    {
        'device': '5gRobot183.srnhz.nsn-rdnet.net',
        'type': '5G_MASTER_RCP_ASIK',
        'location': 'hz'
    }
]

env_status = dict()
env_list_by_type = dict()
queue_by_type = dict()


class Candidate:
    def __init__(self, uuid: str, username: str, required_time: float):
        self._uuid = uuid
        self._username = username
        self._required_time = required_time

    def get_uuid(self):
        return self._uuid

    def get_username(self):
        return self._username

    def get_required_time(self):
        return self._required_time


class EnvState:
    def __init__(self, name):
        self._name = name
        self._assigned = False
        self._started = False
        self._candidate = None
        self._start_time = None
        self._gap_start_time = None
        self._GAP_TIME_LENGTH = 30
        self._WAIT_TIME_LENGTH = 30

    def _log_event(self, msg):
        with open('/var/log/YARS/sct_env_usage_event.log', 'a') as f:
            f.write('[{:s}] {:s}: {:s}'.format(
                datetime.datetime.fromtimestamp(time.time()).strftime('%Y-%m-%d %H:%M:%S.%f'),
                self._name,
                msg
            ))
            if self._candidate:
                f.write(' ({:s}, {:s}, {:f})'.format(
                    self._candidate.get_username(),
                    self._candidate.get_uuid(),
                    self._candidate.get_required_time()
                ))
            f.write('\n')

    def is_free(self):
        """Check if env is free."""
        if not self._assigned:
            # Not assigned
            if self._gap_start_time and (time.time() - self._gap_start_time < self._GAP_TIME_LENGTH):
                # In protection gap
                return False
            else:
                self._gap_start_time = None
                # Really free
                return True
        elif not self._started:
            # Assigned not started
            if time.time() - self._start_time > self._WAIT_TIME_LENGTH:
                # Waiting time over
                self._log_event('WaitTimeOut')
                self.stop()
                # Enter protection gap
                return False
            else:
                # Assigned not free
                return False
        elif self.get_remaining_time() < 0:
            # Running but time over
            self._log_event('RunTimeOut')
            self.stop()
            # Enter protection gap
            return False
        else:
            # Running not free
            return False

    def is_started(self):
        """Return if test is started."""
        return self._started

    def stop(self):
        """Stop test and enter protection gap."""
        self._log_event('Stop')
        self._assigned = False
        self._started = False
        self._candidate = None
        self._start_time = None
        self._gap_start_time = time.time()
        return True

    def assign(self, user):
        """Assign env to user and start waiting."""
        if not self.is_free():
            return False
        self._assigned = True
        self._started = False
        self._candidate = user
        self._start_time = time.time()
        self._gap_start_time = None
        self._log_event('Assign')
        return True

    def start(self):
        """Start running the test."""
        if not self._assigned or self._started:
            return False
        self._started = True
        self._start_time = time.time()
        self._log_event('Start')
        return True

    def get_current_user(self):
        """Return current candidate."""
        return self._candidate

    def get_remaining_time(self):
        """Get remaining time of current test."""
        if not self._assigned:
            return None
        elif not self._started:
            return self._candidate.get_required_time()
        else:
            return self._candidate.get_required_time() - (time.time() - self._start_time)

    def get_time_to_free(self):
        """Get remaining time to free state."""
        if self.is_free():
            # Free
            return 0
        else:
            remaining = self.get_remaining_time()
            if remaining:
                # Assigned
                return remaining + self._GAP_TIME_LENGTH
            else:
                # In protection gap
                return self._GAP_TIME_LENGTH - (time.time() - self._gap_start_time)


class WaitingQueue:
    def __init__(self, queue_name):
        self._queue = list()
        self._user_set = set()
        self._queue_name = queue_name

    def add_candidate(self, candidate):
        uuid = candidate.get_uuid()
        if uuid in self._user_set:
            return False
        self._user_set.add(uuid)
        self._queue.append(candidate)
        return True

    def get_next_candidate(self):
        candidate = self._queue.pop(0)
        self._user_set.remove(candidate.get_uuid())
        return candidate

    def remove_candidate(self, uuid):
        if uuid in self._user_set:
            for candidate in self._queue:
                if candidate.get_uuid() == uuid:
                    self._queue.remove(candidate)
                    break
            self._user_set.remove(uuid)
            return True
        else:
            return False

    def get_queue_length(self):
        return len(self._queue)

    def get_candidate_position(self, uuid):
        pos = 1
        for candidate in self._queue:
            if candidate.get_uuid() == uuid:
                return pos
            pos += 1
        return None


class ApiSctEnvs(Resource):
    def get(self, env_type, uuid):
        """Check and get current queue position and remaining time."""
        response = dict()
        response['error'] = 'No error.'

        if env_type not in env_list_by_type:
            response['error'] = 'Type not found.'
            return response, 404
        queue = queue_by_type[env_type]

        pos = queue.get_candidate_position(uuid)
        
        if pos is None:
            # Candidate not in waiting queue
            for env in env_list_by_type[env_type]:
                env_state = env_status[env]
                current_user = env_state.get_current_user()
                if current_user and current_user.get_uuid() == uuid:
                    # Candidate is assigned to env
                    if not env_state.is_started():
                        env_state.start()
                    response['state'] = 'running'
                    response['device'] = env
                    response['remaining_time'] = env_state.get_remaining_time()
                    return response, 200
            # Candidate not found
            response['error'] = 'Candidate not found.'
            return response, 404
        # Candidate in waiting queue
        min_time_to_free = 0x7fffffffffffffff
        for env in env_list_by_type[env_type]:
            env_state = env_status[env]
            env_state._log_event('{:s}'.format(queue.get_queue_length()))
            if env_state.is_free() and queue.get_queue_length() > 0:
                # Assign next candidate in queue to free env
                next_user = queue.get_next_candidate()
                env_state.assign(next_user)
                if next_user.get_uuid() == uuid:
                    # Is current candidate
                    env_state.start()
                    response['state'] = 'running'
                    response['device'] = env
                    response['remaining_time'] = env_state.get_remaining_time()
            # Find min time to next free env
            time_to_free = env_state.get_time_to_free()
            if time_to_free < min_time_to_free:
                min_time_to_free = time_to_free
        if 'state' not in response:
            # Current candidate still in queue
            response['state'] = 'queuing'
            response['position'] = queue.get_candidate_position(uuid)
            response['queue_length'] = queue.get_queue_length()
            response['next_free_in'] = min_time_to_free
        return response, 200

    def post(self, env_type, uuid):
        """Add new candidate to queue."""
        parser = reqparse.RequestParser()
        parser.add_argument('username')
        parser.add_argument('time')
        args = parser.parse_args()
        response = dict()
        response['error'] = 'No error.'

        if env_type not in env_list_by_type:
            response['error'] = 'Type not found.'
            return response, 404
        queue = queue_by_type[env_type]

        try:
            if not args['username'] or not args['time'] or float(args['time']) < 1:
                response['error'] = 'Bad request.'
                return response, 400
        except ValueError:
            response['error'] = 'Bad request.'
            return response, 400
        candidate = Candidate(uuid, args['username'], float(args['time']) * 60)
        for env in env_list_by_type[env_type]:
            current_user = env_status[env].get_current_user()
            if current_user and current_user.get_uuid() == uuid:
                # Candidate already running
                response['error'] = 'Candidate already exists.'
                return response, 400
        # Add candidate to queue
        if queue.add_candidate(candidate):
            return response, 201
        else:
            # Candidate already in queue
            response['error'] = 'Candidate already exists.'
            return response, 400

    def put(self, env_type, uuid):
        """Do command for the candidate."""
        # parser = reqparse.RequestParser()
        # parser.add_argument('cmd')
        # args = parser.parse_args()
        response = dict()
        response['error'] = 'Command not supported.'

        return response, 400

    def delete(self, env_type, uuid):
        """Release env from the candidate."""
        response = dict()
        response['error'] = 'No error.'

        if env_type not in env_list_by_type:
            response['error'] = 'Type not found.'
            return response, 404
        queue = queue_by_type[env_type]

        if queue.remove_candidate(uuid):
            # Candidate is remove from queue
            return response, 200
        for env in env_list_by_type[env_type]:
            env_state = env_status[env]
            current_user = env_state.get_current_user()
            if current_user and current_user.get_uuid() == uuid:
                # Candidate is assigned to env
                env_state.stop()
                return response, 200
        # Candidate not found
        response['error'] = 'Candidate not found.'
        return response, 400


def init():
    for env in env_list:
        env_type = env['type']
        device = env['device']
        if env_type not in env_list_by_type:
            env_list_by_type[env_type] = set()
        env_list_by_type[env_type].add(device)
        env_state = EnvState(device)
        env_status[device] = env_state
    for env_type in env_list_by_type:
        queue_by_type[env_type] = WaitingQueue(env_type)


def main():
    init()
    app = Flask(__name__)
    api = Api(app)
    api.add_resource(ApiSctEnvs, '/sctenv/<string:env_type>/<string:uuid>')
    app.run(host='0.0.0.0', port=8080, debug=True, threaded=False)


if __name__ == '__main__':
    main()

