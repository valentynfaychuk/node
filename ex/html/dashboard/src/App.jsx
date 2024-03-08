import React, { useState, useEffect, useRef } from 'react';
import {hook_setGlobalState0, wireUpGlobalState, 
  buildInitialState, initialState, globalState, setGlobalState, mergeObjects, doNav} from './state.js'

const globalThis = window; 

const isSafari = /^((?!chrome|android).)*safari/i.test(navigator.userAgent);

function api_amadeus(arg1, setResult) {
  fetch('/api/', {
      method: 'POST', // Specify the request method
      headers: {
          'Content-Type': 'application/json' // Specify the content type of the request body
      },
      body: JSON.stringify({
          arg: arg1,
      })
  })
  .then(response => response.text()) // Parse the JSON response
  .then(data => setResult(data)) // Handle the response data
  .catch(error => setResult('Error:', error)); // Handle any errors
}

function App() {
  const [s, hook_setGlobalState0] = useState(buildInitialState());
  const [data, setData] = useState([]);
  wireUpGlobalState(s, hook_setGlobalState0);

  useEffect(()=> {
  }, [])

  var path = s.path;
  var path_decoded = decodeURI(path.replace("/",""));
  var page = null;

  return (
    <div class="banner">
        <h1>👨‍⚖️ AMADEUS</h1>
    </div>
  );
}

export default App;
